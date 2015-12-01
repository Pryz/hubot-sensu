# Description:
#   Sensu API hubot client
#
# Dependencies:
#   "moment": ">=1.6.0"
#
# Configuration:
#   HUBOT_SENSU_API_URL - URL for the sensu api service.  http://sensu.yourdomain.com:4567
#   HUBOT_SENSU_API_URL_PREFIX - URL prefix to build URL. Example : http://sensu
#   HUBOT_SENSU_API_URL_DOMAIN - URL domain to build URL. Example : mydomain.com
#   HUBOT_SENSU_API_URL_REGION - Default Region to build URL. Example : us-east-1
#   HUBOT_SENSU_API_PORT - Sensu API Port. Example : 4567
#   HUBOT_SENSU_API_USERNAME - Username for the sensu api basic auth. Not used if blank/unset
#   HUBOT_SENSU_API_PASSWORD - Password for the sensu api basic auth. Not used if blank/unset
#   HUBOT_SENSU_API_ALLOW_INVALID_CERTS - Allow self signed and invalid certs. Default:false
#   HUBOT_SENSU_ROLES - using the auth script, what role has access to this.
#                       only supports one role right now.
#
# Commands:
#   hubot sensu info <region> - show sensu api info
#   hubot sensu stashes <region> - show contents of the sensu stash
#   hubot sensu silence <region> <client>[/service] [for \d+[unit]] - silence an alert for an optional period of time (default 1h)
#   hubot sensu remove stash <region> <stash> - remove a stash from sensu
#   hubot sensu clients <region> - show all clients
#   hubot sensu client <region> <client>[ history] - show a specific client['s history]
#   hubot sensu remove client <region> <client> - remove a client from sensu
#   hubot sensu events <region> [ for <client>] - show all events or for a specific client
#   hubot sensu resolve event <region> <client>/<service> - resolve a sensu event
#
# Notes:
#   Requires Sensu >= 0.12 because of expire parameter on stashes and updated /resolve and /request endpoints
#   Checks endpoint not implemented (http://docs.sensuapp.org/0.12/api/checks.html) -- also note /check/request is deprecated in favor of /request
#   Aggregates endpoint not implemented (http://docs.sensuapp.org/0.12/api/aggregates.html)
#
# Authors:
#   Justin Lambert - jlambert121
#   Josh Beard
#

config =
  sensu_api: process.env.HUBOT_SENSU_API_URL
  allow_invalid_certs: process.env.HUBOT_SENSU_API_ALLOW_INVALID_CERTS
  sensu_roles: process.env.HUBOT_SENSU_ROLE
moment = require('moment')

if config.allow_invalid_certs
  http_options = rejectUnauthorized: false
else
  http_options = {}



module.exports = (robot) ->

  validateVars = () ->
    unless config.sensu_api
      robot.logger.error "HUBOT_SENSU_API_URL is unset"
      msg.send "Please set the HUBOT_SENSU_API_URL environment variable."
      return

  build_sensu_url = (region) ->
    host = process.env.HUBOT_SENSU_API_URL_PREFIX + region + "." + process.env.HUBOT_SENSU_API_URL_DOMAIN
    port = process.env.HUBOT_SENSU_API_PORT
    config.sensu_api = "http://#{host}:#{port}"

  createCredential = ->
    username = process.env.HUBOT_SENSU_API_USERNAME
    password = process.env.HUBOT_SENSU_API_PASSWORD
    if username && password
      auth = 'Basic ' + new Buffer(username + ':' + password).toString('base64');
    else
      auth = null
    auth

######################
#### Info methods ####
######################
  robot.respond /sensu help/i, (msg) ->

    cmds = robot.helpCommands()
    cmds = (cmd for cmd in cmds when cmd.match(/(sensu)/))
    msg.send cmds.join("\n")

  robot.respond /sensu info (.*)/i, (msg) ->
    validateVars
    credential = createCredential()
    build_sensu_url(msg.match[1])
    req = robot.http(config.sensu_api + '/info', http_options)
    if credential
      req = req.headers(Authorization: credential)
    req
      .get() (err, res, body) ->
        if err
          msg.send "Sensu says: #{err}"
          return
        if res.statusCode is 200
          result = JSON.parse(body)
          message = "Sensu version: #{result['sensu']['version']}"
          message = message + '\nRabbitMQ: ' + result['transport']['connected'] + ', redis: ' + result['redis']['connected']
          message = message + '\nRabbitMQ keepalives (messages/consumers): (' + result['transport']['keepalives']['messages'] + '/' + result['transport']['keepalives']['consumers'] + ')'
          message = message + '\nRabbitMQ results (messages/consumers):' + result['transport']['results']['messages'] + '/' + result['transport']['results']['consumers'] + ')'
          msg.send message
        else
          msg.send "An error occurred retrieving sensu info (#{res.statusCode}: #{body})"


#######################
#### Stash methods ####
#######################
  robot.respond /(?:sensu)? stashes (.*)/i, (msg) ->
    validateVars
    credential = createCredential()
    build_sensu_url(msg.match[1])
    req = robot.http(config.sensu_api + '/stashes', http_options)
    if credential
      req = req.headers(Authorization: credential)
    req
      .get() (err, res, body) ->
        if err
          msg.send "Sensu says: #{err}"
          return
        results = JSON.parse(body)
        output = []
        for value in results
          console.log value
          message = value['path'] + ' added on ' + moment.unix(value['content']['timestamp']).format('HH:MM YY/M/D')
          if value['content']['reason']
            message = message + ' reason: ' + value['content']['reason']
          if value['expire'] and value['expire'] > 0
            message = message + ', expires in ' + value['expire'] + ' seconds'
          output.push message
        msg.send output.sort().join('\n')

  robot.respond /(?:sensu)? silence ([\w\-]+) (?:http\:\/\/)?([^\s\/]*)(?:\/)?([^\s]*)?(?: for (\d+)(\w))?(.*)/i, (msg) ->
    # msg.match[1] = region
    # msg.match[2] = client
    # msg.match[3] = event (optional)
    # msg.match[4] = duration (optional)
    # msg.match[5] = units (required if duration)
    # msg.match[6] = reason

    validateVars
    client = msg.match[2]

    if msg.match[3]
      path = client + '/' + msg.match[3]
    else
      path = client

    duration = msg.match[4]
    if msg.match[5]
      unit = msg.match[5]
      switch unit
        when 's'
          expiration = duration * 1
        when 'm'
          expiration = duration * 60

        when 'h'
          expiration = duration * 3600
        when 'd'
          expiration = duration * 24 * 3600
        else
          msg.send 'Unknown duration (' + unit + ').  I know s (seconds), m (minutes), h (hours), and d (days)'
          return
      human_d = duration + unit
    else
      expiration = 3600
      human_d = '1h'

    data = {}
    data['content'] = {}
    data['content']['timestamp'] = moment().unix()

    reason = msg.match[6]
    if reason
      data['content']['reason'] = msg.message.user.name + ' silenced: ' + reason
    else
      data['content']['reason'] = msg.message.user.name + ' silenced'

    data['expire'] = expiration
    data['path'] = 'silence/' + path

    credential = createCredential()
    build_sensu_url(msg.match[1])
    req = robot.http(config.sensu_api + '/stashes', http_options)
    if credential
      req = req.headers(Authorization: credential)
    req
      .post(JSON.stringify(data)) (err, res, body) ->
        if res.statusCode is 201
          msg.send path + ' silenced for ' + human_d
        else if res.statusCode is 400
          msg.send 'API returned malformed error for path silence/' + path + '\ndata: ' + JSON.stringify(data)
        else
          msg.send "API returned an error for path silence/#{path}\ndata: #{JSON.stringify(data)}\nresponse:#{res.statusCode}: #{body}"

  robot.respond /(?:sensu)? remove stash ([\w\-]+) (?:http\:\/\/)?(.*)/i, (msg) ->
    validateVars

    stash = msg.match[2]
    unless stash.match /^silence\//
      stash = 'silence/' + stash
    credential = createCredential()
    build_sensu_url(msg.match[1])
    req = robot.http(config.sensu_api + '/stashes/' + stash, http_options)
    if credential
      req = req.headers(Authorization: credential)
    req
      .delete() (err, res, body) ->
        if err
          msg.send "Sensu says: #{err}"
          return
        if res.statusCode is 204
          msg.send stash + ' removed'
        else if res.statusCode is 404
          msg.send stash + ' not found'
        else
          msg.send "API returned an error removing #{stash} (#{res.statusCode}: #{body})"

########################
#### Client methods ####
########################
  robot.respond /sensu clients ([\w\-]+)/i, (msg) ->
    validateVars
    credential = createCredential()
    build_sensu_url(msg.match[1])
    req = robot.http(config.sensu_api + '/clients', http_options)
    if credential
      req = req.headers(Authorization: credential)
    req
      .get() (err, res, body) ->
        if err
          msg.send "Sensu says: #{err}"
          return
        results = JSON.parse(body)
        output = []
        for value in results
          output.push value['name'] + ' (' + value['address'] + ') subscriptions: ' + value['subscriptions'].sort().join(', ')

        if output.length is 0
          msg.send 'No clients'
        else if output.length > 10
          msg.send 'You have too many clients for this'
        else
          msg.send output.sort().join('\n')

  robot.respond /sensu client ([\w\-]+) (?:http\:\/\/)?(.*)( history)/i, (msg) ->
    validateVars
    client = msg.match[2]

    credential = createCredential()
    build_sensu_url(msg.match[1])
    req = robot.http(config.sensu_api + '/clients/' + client + '/history', http_options)
    if credential
      req = req.headers(Authorization: credential)
    req
      .get() (err, res, body) ->
        if err
          msg.send "Sensu says: #{err}"
          return
        if res.statusCode is 200
          results = JSON.parse(body)
          output = []
          for value in results
            output.push value['check'] + ' (last execution: ' + moment.unix(value['last_execution']).format('HH:MM M/D/YY') + ') history: ' + value['history'].join(', ')

          if output.length is 0
            msg.send 'No history found for ' + client
          else
            message = 'History for ' + client + ':\n'
            message = message + output.sort().join('\n')
            msg.send message
        else if res.statusCode is 404
          msg.send client + ' not found'
        else
          msg.send "An error occurred looking up #{client}'s history (#{res.statusCode}: #{body})"

  # get client info (not history)
  robot.respond /sensu client ([\w\-]+) (?:http\:\/\/)?(.*)/i, (msg) ->
    validateVars
    client = msg.match[2]
    # ignore if user asks for history
    if client.match(/\ history/)
      return

    credential = createCredential()
    build_sensu_url(msg.match[1])
    req = robot.http(config.sensu_api + '/clients/' + client, http_options)
    if credential
      req = req.headers(Authorization: credential)
    req
      .get() (err, res, body) ->
        if err
          msg.send "Sensu says: #{err}"
          return
        if res.statusCode is 200
          result = JSON.parse(body)
          msg.send result['name'] + ' (' + result['address'] + ') subscriptions: ' + result['subscriptions'].sort().join(', ')
        else if res.statusCode is 404
          msg.send client + ' not found'
        else
          msg.send "An error occurred looking up #{client} #{res.statusCode}: #{body}"


  robot.respond /(?:sensu)? remove client ([\w\-]+) (?:http\:\/\/)?(.*)/i, (msg) ->
    validateVars
    client= msg.match[2]

    credential = createCredential()
    build_sensu_url(msg.match[1])
    req = robot.http(config.sensu_api + '/clients/' + client, http_options)
    if credential
      req = req.headers(Authorization: credential)
    req
      .delete() (err, res, body) ->
        if err
          msg.send "Sensu says: #{err}"
          return
        if res.statusCode is 202
          msg.send client + ' removed'
        else if res.statusCode is 404
          msg.send client + ' not found'
        else
          msg.send "API returned an error removing #{client} (#{res.statusCode}: #{res.body})"

#######################
#### Event methods ####
#######################
  robot.respond /sensu events ([\w\-]+)(?: for (?:http\:\/\/)?(.*))?/i, (msg) ->
    validateVars
    if msg.match[2]
      client = '/' + msg.match[2]
    else
      client = ''

    credential = createCredential()
    build_sensu_url(msg.match[1])
    req = robot.http(config.sensu_api + '/events' + client, http_options)
    if credential
      req = req.headers(Authorization: credential)
    req
      .get() (err, res, body) ->
        if err
          msg.send "Sensu says: #{err}"
          return
        results = JSON.parse(body)
        output = []
        for value in results
          if value['flapping']
            flapping = ', flapping'
          else
            flapping = ''
          output.push value['client']['name'] + ' (' + value['check']['name'] + flapping + ') - ' + value['check']['output']
        if output.length is 0
          message = 'No events'
          if client != ''
            message = message + ' for ' + msg.match[1]
          msg.send message
        msg.send output.sort().join('\n')

  robot.respond /(?:sensu)? resolve event ([\w\-]+) (?:http\:\/\/)?(.*)(?:\/)(.*)/i, (msg) ->
    validateVars
    client = msg.match[2]

    data = {}
    data['client'] = client
    data['check'] = msg.match[3]

    credential = createCredential()
    build_sensu_url(msg.match[1])
    req = robot.http(config.sensu_api + '/resolve', http_options)
    if credential
      req = req.headers(Authorization: credential)
    req
      .post(JSON.stringify(data)) (err, res, body) ->
        if err
          msg.send "Sensu says: #{err}"
          return
        if res.statusCode is 202
          msg.send 'Event resolved'
        else if res.statusCode is 404
          msg.send msg.match[1] + '/' + msg.match[2] + ' not found'
        else
          msg.send "API returned an error resolving #{msg.match[1]}/#{msg.match[2]} (#{res.statusCode}: #{res.body})"

addClientDomain = (client) ->
  if process.env.HUBOT_SENSU_DOMAIN != undefined
    domainMatch = new RegExp("\.#{process.env.HUBOT_SENSU_DOMAIN}$", 'i')
    unless domainMatch.test(client)
      client = client + '.' + process.env.HUBOT_SENSU_DOMAIN
  client
