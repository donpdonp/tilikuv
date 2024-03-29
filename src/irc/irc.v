module irc

import net
import io
import regex
import time
import db
import chat
import util
import strings

const (
	irc_msg_regex   = r'^([^ ]+) ([^ ]+)( :?([^ ]+)( :?(.*))?)?'
	irc_extra_regex = r'(\S*)(\s+:?([^:]+))?$'
)

pub struct IrcActor {
pub:
	out chan chat.Say
	cin chan Payload
pub mut:
	networks Networks
	puppets  Puppets
}

type Payload = Connect | Disconnect | Joined | NickInUse | PrivMsg

struct NickInUse {
pub mut:
	puppet &Puppet
}

pub struct Connect {
pub:
	puppet &Puppet
}

struct Disconnect {
pub mut:
	puppet &Puppet
}

struct Joined {
pub:
	puppet  &Puppet
	channel string
}

struct PrivMsg {
pub:
	channel string
	puppet  Puppet
	nick    string
pub mut:
	message string
}

pub enum ConnState {
	connected
	disconnected
}

[heap]
pub struct Network {
pub mut:
	name     string
	hostname string
	nick     string
}

pub struct Channels {
pub mut:
	channels []&Channel
}

[heap]
pub struct Channel {
pub mut:
	name   string
	joined bool
}

pub struct Networks {
pub mut:
	networks []&Network
}

pub struct Puppets {
pub mut:
	puppets []&Puppet
}

type SockOrNone = net.TcpConn | util.None

[heap]
pub struct Puppet {
pub mut:
	nick     string
	state    ConnState = ConnState.disconnected
	sock     SockOrNone
	channels Channels
	stop     bool
	network  &Network
}

pub fn setup() &IrcActor {
	actor := &IrcActor{
		cin: chan Payload{cap: 100}
	}
	return actor
}

pub enum SayReturn {
	good
	network_not_found
	user_not_found
	error
}

pub fn (mut self IrcActor) say(network string, nick string, room string, message string) SayReturn {
	mut ircnet := self.networks.by_name(network) or {
		println('irc.say() network "$network" not found. (msg was: $message)')
		return .network_not_found
	}
	mut puppet := self.puppets.by_net_nick(ircnet, nick) or {
		println('irc.say() puppet nick "$nick" not found in ${network}. (msg was: $message)')
		return .user_not_found
	}
	cmd := 'PRIVMSG $room :$message'
	puppet.write(cmd) or { return .error }
	return .good
}

pub fn network_from_db(cols []string) &Network {
	return &Network{
		name: cols[0]
		hostname: cols[1]
		nick: cols[2]
	}
}

pub fn network_to_db(ircnet Network) []db.SqlValue {
	mut ircrow := []db.SqlValue{}
	ircrow << db.SqlValue{
		name: 'hostname'
		value: db.SqlType(ircnet.hostname)
	}
	ircrow << db.SqlValue{
		name: 'netname'
		value: db.SqlType(ircnet.name)
	}
	ircrow << db.SqlValue{
		name: 'nick'
		value: db.SqlType(ircnet.nick)
	}
	return ircrow
}

pub fn (self Network) str() string {
	mut summary := ''
	summary = '$self.name/$self.hostname'
	return summary
}

pub fn (mut self Networks) by_hostname_idx(hostname string) int {
	for idx, ircnet in self.networks {
		// vbug if net == ircnet
		if hostname == ircnet.hostname {
			return idx
		}
	}
	println('error! by_hostname_idx not found $hostname in $self')
	return -1
}

pub fn (mut self Networks) by_hostname(addr string) ?&Network {
	for mut ircnet in self.networks {
		mut p_ircnet := *ircnet // vbug
		if p_ircnet.hostname == addr {
			return p_ircnet
		}
	}
	println('irc.Networks.by_hostname $addr not found in $self.networks')
	return error('server not found')
}

pub fn (mut self Puppet) add_channel(name string) {
	if _ := self.find_channel(name) {
	} else {
		self.channels.channels << &Channel{
			name: name
			joined: true
		}
	}
}

pub fn (self Puppet) find_channel(channel_name string) ?&Channel {
	for channel in self.channels.channels {
		if channel.name == channel_name {
			return channel
		}
	}
	return error('not found')
}

pub fn (mut self IrcActor) connect_all() {
	for mut ircnet in self.networks.networks {
		mut n_ircnet := *ircnet // vbug
		ghost := self.puppets.by_net_nick(n_ircnet, n_ircnet.nick) or {
			mut n_ghost := self.new_ghost(mut n_ircnet, n_ircnet.nick)
			self.connect(mut n_ghost)
			self.puppets.add(mut n_ghost)
		}
		mut g_ghost := *ghost // vbug
		println('irc.connect_all $n_ircnet $g_ghost.nick')
		if g_ghost.state == ConnState.disconnected {
			g_ghost.dial()
		}
	}
}

pub fn dial(hostname string, nick string) SockOrNone {
	mut host := hostname
	if !host.contains(':') {
		host = host + ':6667'
	}
	println('irc.dial() connecting $host $nick')
	mut sock := net.dial_tcp(host) or { return SockOrNone(util.None{}) }

	sock.set_read_timeout(5 * time.minute)
	return SockOrNone(sock)
}

pub fn (mut self Puppet) dial() {
	println('$self.nick dial($self.network.hostname, $self.nick)')
	if self.state == .connected {
		println('$self.nick dial: already connected.')
	} else {
		self.sock = dial(self.network.hostname, self.nick)
		if self.sock is net.TcpConn {
			println('$self.nick dial() connected')
			self.state = .connected
		} else {
			println('$self.nick dial() failed')
		}
	}
}

pub fn (mut self Puppet) join(channel string) {
	println('$self.nick joining $channel')
	cmd := 'JOIN $channel'
	self.write(cmd) or {}
}

pub fn (self IrcActor) find_ghost_idx(nick string) int {
	for idx, ghost in self.puppets.puppets {
		if ghost.nick == nick {
			return idx
		}
	}
	return -1
}

pub fn (mut self IrcActor) new_ghost(mut ircnet Network, nick string) &Puppet {
	mut puppet := &Puppet{
		nick: nick
		network: ircnet
	}
	return puppet
}

pub fn (mut self IrcActor) connect(mut puppet Puppet) {
	puppet.dial()
	if puppet.sock is net.TcpConn {
		go self.comm(mut puppet)
		puppet.signin()
	} else {
		println('WARNING: sock connection failed for $puppet')
	}
}

pub fn (mut self Puppet) signin() {
	nick_cmd := 'nick $self.nick'
	self.write(nick_cmd) or {}
	user_cmd := 'user vbridge b c :full name'
	self.write(user_cmd) or {}
}

pub fn (mut self Puppets) hangup(ircnet &Network) {
	for mut puppet in self.puppets {
		mut p_pup := *puppet
		if p_pup.network.name == ircnet.name {
			p_pup.hangup()
		}
	}
}

pub fn (self &IrcActor) comm(mut puppet Puppet) {
	if mut puppet.sock is net.TcpConn {
		println('$puppet.nick comm() started')
		mut reader := io.new_buffered_reader(reader: puppet.sock)
		for {
			if line := reader.read_line() {
				_ := self.proto(line, mut puppet)
			} else {
				println('$puppet.network $puppet.nick comm() TCP closed $err')
				puppet.hangup()
				payload := Payload(Disconnect{
					puppet: puppet
				})
				match self.cin.try_push(payload) {
					.success {}
					.not_ready { println('WARNING irc.cin channel not ready. channel len $self.cin.len') }
					.closed {}
				}

				// self.cin <-  payload
				break
			}
			if puppet.stop {
				break
			}
		}
		println('$puppet.nick comm() stopped')
	} else {
		println('WARNING: $puppet.nick comm() called with missing socket')
	}
}

pub fn (self &IrcActor) proto(line string, mut puppet Puppet) string {
	// println(line)
	parts := parse(line)
	if parts.len > 0 {
		word := if parts.len == 2 {
			parts[0]
		} else {
			if parts.len > 2 {
				parts[1]
			} else {
				println('irc.proto parse err $parts')
				'E_PARSEERR'
			}
		}
		match word {
			'001' {
				puppet.nick = parts[3] // nick confirmed
			}
			'002' {}
			'003' {}
			'004' {}
			'005' {
				capabilities := capabilities_decode(parts[2])
				if netname := capabilities['NETWORK'] {
					println('$puppet.network.hostname is part of network $netname')
					puppet.network.name = netname
				}
			}
			'250' {
				// highest connection count
			}
			'251' {}
			'252' {}
			'253' {}
			'254' {}
			'255' {}
			'265' {}
			'266' {}
			'332' {
				// room topic
			}
			'333' {
				// room topic set at
			}
			'353' {
				// room nick list
			}
			'366' {
				// end of nicks
			}
			'372' {
				// drop motd
			}
			'376' {
				// end of motd
				println('irc.proto 376 end of motd - Connect $puppet.network.name $puppet.nick')
				puppet.state = .connected
				self.cin <- Payload(Connect{
					puppet: puppet
				})
			}
			'433' {
				println('$puppet irc.proto 433 nick $puppet.nick already in use! aborting connection')
				self.cin <- Payload(NickInUse{
					puppet: puppet
				})
			}
			'NICK' {
				//[':donpdonp|z_!~donp@1.2.3.4', 'NICK', ' :donpdonp|z', 'donpdonp|z']
				println(parts) // debug
				nick_parts := nick_parse(parts[0][1..])
				if nick_parts[0] == puppet.nick {
					println('NICK changing puppet $puppet.nick to ${parts[3]}')
					puppet.nick = parts[3]
				} else {
					println('$puppet.nick heard NICK change for ${nick_parts[0]} -> ${parts[3]}. ignoring')
				}
			}
			'NOTICE' {}
			'JOIN' {
				println('sock ${ptr_str(puppet.sock)} $line')
				//:donp|m!~a@64.62.134.149 JOIN #roomy-room
				nick_parts := nick_parse(parts[0][1..])
				channel := parts[3]
				println('$puppet.network $puppet.nick puppet ${ptr_str(puppet)}: ${nick_parts[0]} JOINed $channel')
				if nick_parts[0] == puppet.nick {
					puppet.add_channel(channel)
					self.cin <- Payload(Joined{
						puppet: puppet
						channel: channel
					})
				}
			}
			'PING' {
				reply := 'PONG ${parts[1]}'
				puppet.write(reply) or {}
			}
			'PRIVMSG' {
				// [':donpdonp!~vbridge@64.62.134.149', 'PRIVMSG', ' #robots :hi there', '#robots', ' :hi there', 'hi there']
				mut privmsg := PrivMsg{
					channel: parts[3]
					puppet: puppet
					nick: parts[0][1..] // remove : from protocol
					message: ''
				}
				if ctcp := util.ctcp_decode(parts[5]) {
					ctcp_parts := ctcp.split(' ')
					match ctcp_parts[0] {
						'VERSION' {}
						'ACTION' {
							privmsg.message = parts[5]
							self.cin <- Payload(privmsg)
						}
						else {
							privmsg.message = 'unknown CTCP: ' + ctcp
							self.cin <- Payload(privmsg)
						}
					}
				} else {
					privmsg.message = color_strip(parts[5])
					self.cin <- Payload(privmsg)
				}
			}
			'MODE' {
				//:tbridge MODE tbridge :+i
			}
			else {
				println('$word $parts')
			}
		}
	}
	return ''
}

pub fn color_strip(msg string) string {
	// https://modern.ircdocs.horse/formatting.html
	mut new_msg := strings.new_builder(msg.len)
	runes := msg.runes()
	msg_len := runes.len
	for idx := 0; idx < msg_len; idx += 1 {
		chr := runes[idx]
		if chr == 0x03 { // start color
			idx++
			idx++
		} else {
			new_msg.write_rune(chr)
		}
	}
	return new_msg.str()
}

pub fn nick_parse(full_nick string) []string {
	// donp|m!~a@64.62.134.149
	mut parts := []string{}
	parts << full_nick.before('!')
	return parts
}

pub fn parse(line string) []string {
	mut parts := []string{}
	mut re := regex.regex_opt(irc.irc_msg_regex) or { panic(err) }
	re.match_string(line.trim_string_right('\n'))
	for g_index := 0; g_index < re.group_count; g_index++ {
		start, end := re.get_group_bounds_by_id(g_index)
		if start >= 0 {
			parts << line[start..end]
		}
	}
	return parts
}

pub fn (self &IrcActor) is_room(room string) bool {
	room_match := r'^#[-A-Za-z0-9_]+$'
	mut re := regex.regex_opt(room_match) or { panic('regex fail') }
	start, _ := re.match_string(room)
	println('irc:is_room $room $room_match $start')
	return start > -1
}

pub fn (self PrivMsg) str() string {
	return '$self.puppet.network $self.puppet.nick: $self.channel $self.nick $self.message'
}

pub fn (self Channels) find_by_name(name string) ?&Channel {
	for channel in self.channels {
		println('irc.find_by_name [mtx] $name == [irc] $channel.name')
		if channel.name == name {
			return channel
		}
	}
	return error('not found')
}

pub fn (mut self IrcActor) find_channel_by_name(nick string, channel_name string) ?&Channel {
	if ghost := self.puppets.by_nick(nick) {
		if channel := ghost.channels.find_by_name(channel_name) {
			return channel
		} else {
			println('irc.find_channel_by_name() $ghost.nick ghost ${ptr_str(ghost)} has no $channel_name')
			dump(ghost.channels)
		}
	}
	return error('not found')
}

pub fn (self Puppets) by_network(netname string) []&Puppet {
	mut winners := []&Puppet{}
	for g in self.puppets {
		if g.network.name == netname {
			winners << g
		}
	}
	return winners
}

pub fn (mut self Puppets) by_nick(nick string) ?&Puppet {
	for mut puppet in self.puppets {
		p_pup := *puppet
		if p_pup.nick == nick {
			println("irc.Puppets.by_nick(\"$nick\") found ghost.nick ${ptr_str(p_pup.nick)} \"$p_pup.nick\" ")
			return p_pup
		}
	}
	return error('not found')
}

pub fn (mut self Networks) add(network &Network) &Network {
	self.networks << network
	return self.networks.last() // network was copied. return copy.
}

pub fn (mut self Networks) by_name(name string) ?&Network {
	for mut puppet in self.networks {
		mut p_net := *puppet
		if p_net.name == name {
			return p_net
		}
	}
	return error('not found')
}

pub fn (self Channel) str() string {
	return '$self.name'
}

pub fn (self Puppets) by_net_nick(ircnet Network, nick string) ?&Puppet {
	for g in self.puppets {
		if g.nick == nick && g.network.name == ircnet.name {
			println("irc.Puppets.by_net_nick(\"$ircnet.name\" \"$nick\") found ghost.nick ${ptr_str(g.nick)} \"$g.nick\" ")
			return g
		}
	}
	return error('not found')
}

pub fn (mut self Puppet) nick(nick string) {
	self.write('NICK $nick') or {}
}

pub fn (mut self Puppet) write(msg string) ? {
	if mut self.sock is net.TcpConn {
		println('$self.network $self.nick: $msg')
		self.sock.write_string(msg + '\n') or {
			println('$self.network $self.nick: socket write error $err')
			self.hangup()
		}
	} else {
		errmsg := 'NO SOCK: $self.network $self.nick: dropped $msg'
		println(errmsg)
		return error(errmsg)
	}
}

pub fn (mut self Puppet) hangup() {
	println('$self.nick hangup()')
	if mut self.sock is net.TcpConn {
		println('$self.nick sock.close()')
		self.sock.close() or { println('$self.nick sock.close $err') }
	}
	self.state = ConnState.disconnected
	self.channels.channels.clear()
}

pub fn (self Puppet) str() string {
	return '${ptr_str(self)} nick:$self.nick sock:${ptr_str(self.sock)} conn: $self.state channels:$self.channels'
}

pub fn (mut self Puppets) add(mut puppet Puppet) &Puppet {
	self.puppets << puppet
	return self.puppets.last() // puppet was copied. return copy.
}

pub fn capabilities_decode(capstr string) map[string]string {
	parts := capstr.split(' ')
	mut cap := map[string]string{}
	for part in parts {
		cap_parts := part.split('=')
		if cap_parts.len == 2 {
			key := cap_parts[0]
			value := cap_parts[1]
			cap[key] = value
		}
	}
	return cap
}
