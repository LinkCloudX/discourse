# frozen_string_literal: true
require 'digest/sha1'

class UserAuthToken < ActiveRecord::Base
  belongs_to :user

  # TODO 2019: remove this line
  self.ignored_columns = ["legacy"]

  ROTATE_TIME = 10.minutes
  # used when token did not arrive at client
  URGENT_ROTATE_TIME = 1.minute

  USER_ACTIONS = ['generate']

  attr_accessor :unhashed_auth_token

  before_destroy do
    UserAuthToken.log(action: 'destroy',
                      user_auth_token_id: self.id,
                      user_id: self.user_id,
                      user_agent: self.user_agent,
                      client_ip: self.client_ip,
                      auth_token: self.auth_token)
  end

  def self.log(info)
    if SiteSetting.verbose_auth_token_logging
      UserAuthTokenLog.create!(info)
    end
  end

  # Returns the login location as it will be used by the the system to detect
  # suspicious login.
  #
  # This should not be very specific because small variations in location
  # (i.e. changes of network, small trips, etc) will be detected as suspicious
  # logins.
  #
  # On the other hand, if this is too broad it will not report any suspicious
  # logins at all.
  #
  # For example, let's choose the country as the only component in login
  # locations. In general, this should be a pretty good choce with the
  # exception that for users from huge countries it might not be specific
  # enoguh. For US users where the real user and the malicious one could
  # happen to live both in USA, this will not detect any suspicious activity.
  def self.login_location(ip)
    DiscourseIpInfo.get(ip)[:country]
  end

  def self.is_suspicious(user_id, user_ip)
    return false unless User.find_by(id: user_id)&.staff?

    ips = UserAuthTokenLog.where(user_id: user_id).pluck(:client_ip)
    ips.delete_at(ips.index(user_ip) || ips.length) # delete one occurance (current)
    ips.uniq!
    return false if ips.empty? # first login is never suspicious

    user_location = login_location(user_ip)
    ips.none? { |ip| user_location == login_location(ip) }
  end

  def self.generate!(user_id: , user_agent: nil, client_ip: nil, path: nil, staff: nil, impersonate: false)
    token = SecureRandom.hex(16)
    hashed_token = hash_token(token)
    user_auth_token = UserAuthToken.create!(
      user_id: user_id,
      user_agent: user_agent,
      client_ip: client_ip,
      auth_token: hashed_token,
      prev_auth_token: hashed_token,
      rotated_at: Time.zone.now
    )
    user_auth_token.unhashed_auth_token = token

    log(action: 'generate',
        user_auth_token_id: user_auth_token.id,
        user_id: user_id,
        user_agent: user_agent,
        client_ip: client_ip,
        path: path,
        auth_token: hashed_token)

    if staff && !impersonate
      Jobs.enqueue(:suspicious_login,
        user_id: user_id,
        client_ip: client_ip,
        user_agent: user_agent)
    end

    user_auth_token
  end

  def self.lookup(unhashed_token, opts = nil)
    mark_seen = opts && opts[:seen]

    token = hash_token(unhashed_token)
    expire_before = SiteSetting.maximum_session_age.hours.ago

    user_token = find_by("(auth_token = :token OR
                          prev_auth_token = :token) AND rotated_at > :expire_before",
                          token: token, expire_before: expire_before)

    if !user_token

      log(action: "miss token",
          user_id: user_token&.user_id,
          auth_token: token,
          user_agent: opts && opts[:user_agent],
          path: opts && opts[:path],
          client_ip: opts && opts[:client_ip])

      return nil
    end

    if user_token.auth_token != token && user_token.prev_auth_token == token && user_token.auth_token_seen
      changed_rows = UserAuthToken
        .where("rotated_at < ?", 1.minute.ago)
        .where(id: user_token.id, prev_auth_token: token)
        .update_all(auth_token_seen: false)

      # not updating AR model cause we want to give it one more req
      # with wrong cookie
      UserAuthToken.log(
        action: changed_rows == 0 ? "prev seen token unchanged" : "prev seen token",
        user_auth_token_id: user_token.id,
        user_id: user_token.user_id,
        auth_token: user_token.auth_token,
        user_agent: opts && opts[:user_agent],
        path: opts && opts[:path],
        client_ip: opts && opts[:client_ip]
      )
    end

    if mark_seen && user_token && !user_token.auth_token_seen && user_token.auth_token == token
      # we must protect against concurrency issues here
      changed_rows = UserAuthToken
        .where(id: user_token.id, auth_token: token)
        .update_all(auth_token_seen: true, seen_at: Time.zone.now)

      if changed_rows == 1
        # not doing a reload so we don't risk loading a rotated token
        user_token.auth_token_seen = true
        user_token.seen_at = Time.zone.now
      end

      log(action: changed_rows == 0 ? "seen wrong token" : "seen token",
          user_auth_token_id: user_token.id,
          user_id: user_token.user_id,
          auth_token: user_token.auth_token,
          user_agent: opts && opts[:user_agent],
          path: opts && opts[:path],
          client_ip: opts && opts[:client_ip])
    end

    user_token
  end

  def self.hash_token(token)
    Digest::SHA1.base64digest("#{token}#{GlobalSetting.safe_secret_key_base}")
  end

  def self.cleanup!

    if SiteSetting.verbose_auth_token_logging
      UserAuthTokenLog.where('created_at < :time',
            time: SiteSetting.maximum_session_age.hours.ago - ROTATE_TIME).delete_all
    end

    where('rotated_at < :time',
          time: SiteSetting.maximum_session_age.hours.ago - ROTATE_TIME).delete_all

  end

  def rotate!(info = nil)
    user_agent = (info && info[:user_agent] || self.user_agent)
    client_ip = (info && info[:client_ip] || self.client_ip)

    token = SecureRandom.hex(16)

    result = DB.exec("
  UPDATE user_auth_tokens
  SET
    auth_token_seen = false,
    seen_at = null,
    user_agent = :user_agent,
    client_ip = :client_ip,
    prev_auth_token = case when auth_token_seen then auth_token else prev_auth_token end,
    auth_token = :new_token,
    rotated_at = :now
  WHERE id = :id AND (auth_token_seen or rotated_at < :safeguard_time)
", id: self.id,
   user_agent: user_agent,
   client_ip: client_ip&.to_s,
   now: Time.zone.now,
   new_token: UserAuthToken.hash_token(token),
   safeguard_time: 30.seconds.ago
  )

    if result > 0
      reload
      self.unhashed_auth_token = token

      UserAuthToken.log(
        action: "rotate",
        user_auth_token_id: id,
        user_id: user_id,
        auth_token: auth_token,
        user_agent: user_agent,
        client_ip: client_ip,
        path: info && info[:path]
      )

      true
    else
      false
    end

  end
end

# == Schema Information
#
# Table name: user_auth_tokens
#
#  id              :integer          not null, primary key
#  user_id         :integer          not null
#  auth_token      :string           not null
#  prev_auth_token :string           not null
#  user_agent      :string
#  auth_token_seen :boolean          default(FALSE), not null
#  client_ip       :inet
#  rotated_at      :datetime         not null
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  seen_at         :datetime
#
# Indexes
#
#  index_user_auth_tokens_on_auth_token       (auth_token) UNIQUE
#  index_user_auth_tokens_on_prev_auth_token  (prev_auth_token) UNIQUE
#
