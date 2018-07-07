#!/usr/bin/env ruby

require "net/http"
require 'openssl'
require "uri"
require "yaml"
require "pp"

@settings = Hash.new

def check_site(site_name, headers, ignore_ssl_errors, site_url, searchstring, site_timeout, maxredirects)
  url = URI.parse(site_url)
  url.path = "/" if url.path.empty? #Default request to '/'
  url.scheme = 'http' if url.scheme.nil? #Default scheme to 'http'
  
  connection = Net::HTTP.new(url.host, url.port)
  connection.use_ssl = url.scheme == 'https'
  connection.verify_mode = OpenSSL::SSL::VERIFY_NONE if connection.use_ssl? && ignore_ssl_errors == true
  
  request = Net::HTTP::Get.new(url.path)
  request['host'] = url.host #default
  
  headers.each do |k,v|
    request[k] = v
  end
 
  response = nil

  begin
    Timeout::timeout site_timeout.to_i do
      response = connection.request(request)
    end
  rescue Timeout::Error
    return false, "Connection timed out"
  rescue => e
    return false, "Connection timed out: #{e.message}"
  end

  #Did we get the site, or get redirected?
  case response.code[0] #200 -> 2, 404 -> 4
    when "2" #OK response
      #Check the response body for searchtext
      if ! response.body.nil? then 
        if response.body.include? searchstring
          return true, "'#{searchstring}' is online"
        else
          return false, "Search text '#{searchstring}' not found"
        end
      else
        return false, "Empty response body!"
      end
    when "1","4","5" #errors
      #Catch common server errors
      return false, "HTTP Error #{response.code}"
    when "3" #redirect
      return false, "Hit max clients" if maxredirects <= 0
      
      #Get redirect location
      if response.header['location'].nil? then
        return false, "Bad redirect. Empty location. Response code: #{response.code}"
      else
        redirect_location = response['Location']
        redirect_uri = URI.parse(redirect_location)
      end
      
      if redirect_uri.host.nil? then
        #We were redirected to a URL with no hostname, like "/"
        redirect_location = site_url.scheme + '://' + site_url.host + redirect_location      
      elsif ! headers['host'].nil? && redirect_uri.host != headers['host'] then
        #user has specifically requested that we send a static 'host' header to this site
        #but we're being redirected to a location where the hostname doesn't match the host header we're sending (going to a different site)
        #change the static host header to match the redirect location's host header value
        print_message("info", "Host header that we sent (\"#{headers['host']}\") differs from redirect location's hostname (\"#{redirect_uri.host}\"). Correcting...")
	headers['host'] = redirect_uri.host
      elsif ! headers['host'].nil? && redirect_uri.host == headers['host']
        #user has specifically requested that we send a static 'host' header to this site
        #we're being redirected to a location where the hostname matches what we have in our static 'host' header
        #replace the redirect hostname with what we have listed in site_url.host (likely an IP address) - http://>1.1.1.1<
        #NORMAL    http://1.1.1.1 (host: web.com) -> https://web.com/
        #CORRECTED http://1.1.1.1 (host: web.com) -> https://1.1.1.1 (host: web.com)
        print_message("info", "Redirect location hostname (\"#{redirect_uri.host}\") matches 'host' header in configuration (\"#{headers['host']}\"). Replacing with \"#{url.host}\"...")
        redirect_location.sub! headers['host'], url.host
      end
  
      #Call method again with new redirect URL. Decrement maxredirects
      print_message("info", "Following redirect to #{redirect_location}...")
      check_site(site_name, headers, ignore_ssl_errors, redirect_location, searchstring, site_timeout, maxredirects -1)
  end
end

def history_add(site_history, isup)
  isup == true ? site_history.unshift(0) : site_history.unshift(1)
  return site_history.slice(0..@settings['history_len'] - 1 )
end

def get_state_changes(history)
  last_state = history[0]
  state_changes = 0 #1->0 or 0->1
  
  history.each do |i| #each history item for url
    if last_state != i then
      state_changes += 1
    end
    last_state = i
  end

  return state_changes
end

def should_alert(history, current_status)
  #Check the history for a URL and return true/false
  #depending on the change_threshold setting for if an
  #alerts needs to be sent or not

  #Defines number of consecutive 1's or 0's until a site is condidered up or down
  change_thresh = @settings['change_threshold']

  #Define number of state changes until a site is considered down-flapping
  flap_thresh = @settings['flap_threshold']

  latest_zeros = 0
  latest_ones = 0

  #Get the last change_thresh checks for site
  #And count the 1's and 0's (1=down, 0=up)
  (change_thresh).times do |i|
    history[i] == 0 ? latest_zeros += 1 : latest_ones += 1
  end

  #count the number of 0->1 and 1->0 changes in url history
  #to check for flapping
  state_changes = get_state_changes(history)

  #Check for flapping
  if state_changes >= flap_thresh #Site flapping/down?
    if current_status == "flap"
      return false, "still_flapping", current_status #Site is still flapping/down. Consider it down don't alert
    else
      current_status = "flap"
      return true, "new_flapping", current_status #Site was not flapping. Is now flapping/down. Alert
    end
  end

  #Check for up/down
  if latest_ones == change_thresh #Site down?
    if current_status == "down"
      return false, "still_down", current_status #Site is still down. Don't alert
    else
      current_status = "down"
      return true, "new_down", current_status #Site was up. Is now down. Alert
    end
  elsif latest_zeros == change_thresh #Site up?
    if current_status == "up"
      return false, "still_up", current_status #Site is still up. Don't alert
    else
      current_status = "up"
      return true, "new_up", current_status #Site was down. Is now up. Alert
    end
  else
    #Site is neither full-count up nor full-cound down.
    #The last change_thresh checks have a mix of 1's and 0's
    #Maybe is just came back up. Maybe it just went down.
    #Return 'false', as we don't want to alert yet until we meed the threshold
    return false, "between-state", current_status
  end
end

def print_message(type, message, send_telegram = false)
  if type == "error"
    puts "\e[1m\e[31m#{Time.now.strftime("%Y-%m-%d %H:%M")} - #{message}\e[0m\e[22m"
  elsif type == "warn"
    puts "\e[33m#{Time.now.strftime("%Y-%m-%d %H:%M")} - #{message}\e[0m"
  elsif type == "success"
    puts "\e[32m#{Time.now.strftime("%Y-%m-%d %H:%M")} - #{message}\e[0m"
  elsif type == "info"
    puts "#{Time.now.strftime("%Y-%m-%d %H:%M")} - #{message}"
  end

  if send_telegram == true
    begin
      botkey = @settings['telegram_botkey']
      chatid = @settings['telegram_chatid']

      message = Time.now.strftime("%Y-%m-%d %H:%M") + ": " + message

      uri = URI("https://api.telegram.org/bot#{botkey}/sendMessage")

      res = Net::HTTP.post_form(uri, 'chat_id' => chatid, 'disable_web_page_preview' => '1', 'text' => message)
      print_message("info", "Sent Telegram alert")
    rescue
      print_message("error", "Failed to send Telegram alert! Reason: " + $!.message)
    end
  end
end

def read_sites(sites_dir)
  print_message("info", "Loading sites '#{sites_dir}/*.yml'...")

  site_files = Dir.glob("#{sites_dir}/*.yml")
  sites = Hash.new

  begin
    site_files.each do |f|
      YAML.load_file(f).each do |site_name,settings|
        url = settings["url"]
        search = settings["search"]

        #Correct URL if needed
        if ! url.include? "http"
          print_message("warn", "Site '#{url}' is missing 'http/https' prefix. Defaulting to 'http://' for this site")
          url = "http://#{url}"
        end
 
        #Add site_name => {option => value, ...}
        sites[site_name] = settings
 
        print_message("info", "Loaded site '#{site_name}'")
      end
    end

    print_message("info", "Finished loading all sites")
    return sites
  rescue
    print_message("error", "Failed to load sites from '#{file}'! Reason: #{$!.message}")
    print_message("info", "Exiting..")
    exit
  end
end

def read_settings(settings_file)

  print_message("info", "Loading settings from '#{settings_file}'...")

  begin
    YAML.load_file(settings_file).each do |k,v|
      @settings[k] = v
      print_message("info","Added setting '#{k}' -> '#{v}'")
    end
    print_message("info", "Finished loading all settings")
  rescue
    print_message("error", "Failed to load settings from '#{settings_file}. Reason: #{$!.message}")
  end
end

#Disabled output buffering so that
#systemd can see our stdout messages in realtime
STDOUT.sync = true

#Load settings.yml
read_settings("settings.yml")

#Load sites.yml
sites = read_sites("sites.d")

#Add 'history' array for each site
#{ url => [0,0,0,0,0] }
sites.each do |site, options|
  options["history"] = Array.new(@settings['history_len'], 0)
end

#Add 'current_status' for each site
sites.each do |site, options|
  options["current_status"] = "up"
end

puts "-" * 30
print_message("info", "Testing sites...")

#Main loop - Check each site
while true
  sites.each do |site_name, options|
    puts #Add a line break

    url = options["url"]
    headers = options["http_headers"]
    searchstring = options["search"]
    timeout = options["timeout"]
    maxredirect = options["max_redirect"]
    ignore_ssl_errors = options["ignore_ssl_errors"]

    print_message("info", "Testing #{site_name} (#{url})")
    print_message("info", "Using headers #{headers}")

    #Get the current time before checking site
    start_time = Time.now

    #Check the site to see if it's online or not
    lastcheck_online, description = check_site(site_name, headers, ignore_ssl_errors, url, searchstring, timeout, maxredirect)

    #Get time diff after site checked
    request_time = Time.now - start_time 
    
    #Add the latest check to the site's history
    history = sites[site_name]["history"]
    sites[site_name]["history"] = history_add(history, lastcheck_online)
    history = sites[site_name]["history"]

    #Determine if we should alert or not based on the site's history
    current_status = options["current_status"]
    doalert, alert_status, new_site_status = should_alert(history, current_status)

    #Update site's status with new status
    sites[site_name]["current_status"] = new_site_status

    case alert_status
      when "still_down"
        print_message("error", "'#{site_name}' is still flagged: OFFLINE (#{request_time} ms). #{history} Reason: " + description, doalert)
      when "new_down"
        print_message("error", "'#{site_name}' is now flagged: OFFLINE (#{request_time} ms). #{history} Reason: " + description, doalert)
    
      when "still_flapping"
        print_message("error", "'#{site_name}' is still flagged: FLAPPING/OFFLINE (#{request_time} ms). #{history}", doalert)
      when "new_flapping"
        print_message("error", "'#{site_name}' is now flagged: FLAPPING/OFFLINE (#{request_time} ms). #{history}", doalert)
      
      when "still_up"
        print_message("success", "'#{site_name}' is still flagged: ONLINE (#{request_time} ms). #{history}", doalert)
      when "new_up"
        print_message("success", "'#{site_name}' is now flagged: ONLINE (#{request_time} ms). #{history}", doalert)
      
      when "between-state"
        #Determine if we're going from 0->1 or 1->0
        if lastcheck_online == true
          print_message("success", "'#{site_name}' is online (#{request_time} ms). #{history}", doalert)
        else
          print_message("error", "'#{site_name}' is offline (#{request_time} ms). #{history} Reason: " + description, doalert)
        end
      end
  end
  sleep @settings['looptimer']
end
