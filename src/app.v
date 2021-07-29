module main

import time
import setup
import irc
import matrix
import rpc
import appsvc
import db
import chat
import regex
import util
import bridge
import x.json2

struct Main {
mut:
	irc     &irc.IrcActor
	appsvc  &appsvc.AppsvcActor
	matrix  &matrix.Actor
	rpc     &rpc.Actor
	config  setup.Config
	db      db.Db
	chat    &chat.Actor
	aliases chat.Aliases
}

fn main() {
	config := setup.config()
	mut main := &Main{
		irc: irc.setup()
		appsvc: appsvc.setup(config)
		matrix: matrix.init(config)
		rpc: rpc.init(config)
		config: config
		db: db.init(config)
		chat: chat.setup(config)
	}
	go main.listen_out()
	go main.matrix.setup()
	go main.appsvc.listen()
	go main.rpc.listen()
	go main.matrix.listen()
	go main.irc.listen()
	irchosts := main.db.select_all('irc_servers')
	for row in irchosts {
		ircnet := irc.network_from_db(row)
		main.irc.networks.add(ircnet)
	}
	println('loaded $irchosts.len irc networks')
	aliases := main.db.select_all('bridge_nicks')
	for alias in aliases {
		main.aliases.add(&chat.Alias{ matrix: alias[0], irc: alias[1] })
	}
	println('loaded $aliases.len matrix/irc aliases')
	main.mainloop()
}

fn (mut self Main) mainloop() {
	for {
		select {
			irc_m := <-self.irc.cin {
				self.irc_do(irc_m)
			}
			matrix := <-self.matrix.cin {
				self.matrix_do(matrix)
			}
			appsvc := <-self.appsvc.out {
				self.as_do(appsvc)
			}
			rpc := <-self.rpc.out {
				self.rpc_do(rpc)
			}
			chat_payload := <-self.chat.cin {
				self.chat_do(chat_payload)
			}
			60 * time.minute {
				println('$time.now()')
			}
		}
	}
}

fn (mut self Main) chat_do(payload chat.Payload) {
	println(payload)
	match payload {
		chat.MakeIrcUser {
			mut ircnet := self.irc.networks.by_name(payload.network_hostname) or {
				println('chat_do() not found: $payload.network_hostname')
				return
			}
			mut puppet := self.irc.new_ghost(mut ircnet, payload.nick)
			self.irc.connect(mut puppet)
			self.irc.puppets.add(mut puppet)
		}
		else {}
	}
}

fn (mut self Main) matrix_do(payload matrix.Payload) {
	match payload {
		matrix.Connect {
			joined_room_ids := self.matrix.joined_rooms() or {
				println('$err')
				return
			}
			mut matrix_rooms := []&matrix.Room{}
			for jroom_id in joined_room_ids {
				db_room := self.db.select_by_field('matrix_rooms', 'room_id', jroom_id)
				mut mroom := &matrix.Room{}
				if db_room.len > 0 {
					mroom = matrix.room_from_db(db_room[0])
				} else {
					println('warning: joined room $jroom_id not found in db')
					mroom = &matrix.Room{
						id: jroom_id
						name: util.StringOrNone(&util.None{})
					}
				}
				println('matrix room loaded $mroom')
				matrix_rooms << mroom
			}
			self.matrix.joined_rooms.replace(matrix_rooms)
			println('Matrix $self.config.matrix_host sync_rooms')
			self.sync_matrix_rooms()
			println('Matrix $self.config.matrix_host SETUP done')
			alias := &chat.Alias{
				matrix: self.matrix.whoami
				irc: matrix.split(self.matrix.whoami)[1]
			}
			self.aliases.add(alias)
			self.admin_say('* vbridge started. I am $self.matrix.whoami')
			// start IRC setup after matrix
			println('connecting $self.irc.networks.networks.len irc networks')
			go self.irc.connect_all()
		}
		matrix.MakeUser {
			// register user, join room, and try again
			if _ := self.matrix.register(payload) {
				self.admin_say('registered $payload')
				self.process_out_user(payload.user_id)
			} else {
				self.admin_say('matrix registration error for $payload: $err')
			}
		}
		matrix.JoinRoom {
			self.matrix.join_as(payload.name, payload.room) or {}
			self.process_out_user(payload.name)
		}
		else {}
	}
}

fn (mut self Main) irc_do(irc_m irc.Payload) {
	match irc_m {
		irc.PrivMsg {
			println('<- $irc_m')
			if irc_m.channel == irc_m.puppet.network.nick {
				room := irc_m.nick[1..].split('!')[0]
				self.command(chat.System.irc, irc_m.puppet.network.name, irc_m.nick, room,
					irc_m.message[1..])
			} else {
				// when bridgebot hears it, repeat in matrix
				if irc_m.puppet.nick == irc_m.puppet.network.nick {
					partial_irc_nick := irc_m.nick.split('!')[0]
					if _ := self.irc.puppets.by_net_nick(irc_m.puppet.network, partial_irc_nick) {
						println('info: $partial_irc_nick is a ghost. not relaying.')
					} else {
						full_channel := '$irc_m.channel:$irc_m.puppet.network.name'
						if room_name := bridge.matching_room(full_channel, mut self.db) {
							if mroom := self.matrix.joined_rooms.find_room_by_name(room_name) {
								matrix_name := self.name_convert(chat.System.irc, partial_irc_nick)
								self.chat.say(chat.System.matrix, matrix_name, '', mroom.id,
									irc_m.message)
							} else {
								println('warning: no matrix.joined_rooms for $room_name')
							}
						} else {
							println('warning: no bridge found for $full_channel msg dropped: $irc_m.message')
						}
					}
				}
			}
		}
		irc.Connect {
			user_id := self.name_convert(.irc, irc_m.puppet.nick)
			msg := '${irc_m.puppet.nick}($user_id) connected to $irc_m.puppet.network'
			self.matrix_say(user_id, msg)
			self.sync_irc_channels(irc_m.puppet)
		}
		irc.Disconnect {
			user_id := self.name_convert(.irc, irc_m.puppet.nick)
			msg := '$irc_m.puppet.nick disconnected from $irc_m.puppet.network.hostname use !irc connect'
			self.matrix_say(user_id, msg)
			mut puppet := self.irc.puppets.by_nick(irc_m.puppet.nick) or { return } // mut hack
			self.irc.connect(mut puppet)
		}
		irc.Joined {
			user_id := self.name_convert(.irc, irc_m.puppet.nick)
			msg := '$irc_m.puppet.nick joined $irc_m.channel on $irc_m.puppet.network.name'
			self.matrix_say(user_id, msg)
			self.process_out_user(irc_m.puppet.nick)
		}
		irc.NickInUse {
			user_id := self.name_convert(.irc, irc_m.puppet.nick)
			msg := '$irc_m.puppet.nick is already in use on $irc_m.puppet.network.name'
			self.matrix_say(user_id, msg)
			mut puppet := self.irc.puppets.by_nick(irc_m.puppet.nick) or { return } // mut hack
			puppet.hangup()
		}
	}
}

fn (mut self Main) rpc_do(cmd rpc.Command) {
	self.command(chat.System.irc, 'rpc', 'rpc', 'rpc', '$cmd.verb ${cmd.params['line']}')
}

fn (mut self Main) as_do(cmd appsvc.Command) {
	// println('as_do: ${cmd.data['id']} ${cmd.data['type']}')
	match cmd.data['type'].str() {
		'm.room.name' {
			println('m.room.name $cmd')
		}
		'm.room.member' {
			println('m.room.member $cmd')
			c := cmd.data['content'].as_map()
			room_id := cmd.data['room_id'].str()
			whoami := cmd.data['state_key'].str()
			println('m.room.member user ${cmd.data['state_key']} room_id $room_id is ${c['membership']}')
			membership := c['membership'].str()
			match membership {
				'invite' {
					room_alias := self.matrix.invited_by(cmd.data)
					println('matrix invite invited by $room_alias')
					match self.join_request_matrix(room_alias, room_id) {
						.saved {
							self.admin_say('recorded $room_id')
							self.sync_matrix_rooms()
						}
						.already_joined {
							self.admin_say('already joined $room_id')
						}
					}
				}
				'join' {
					mut msg := ''
					if room := self.matrix.joined_rooms.find_room_by_id(room_id) {
						if room.name is string {
							room_name := room.name // VBUG
							msg = '$whoami joined ${room_name}.'
							if room_name.starts_with('@') {
								msg = msg + ' (DM room)'
							} else {
								if channel := bridge.matching_room(room_name, mut self.db) {
									msg = msg + ' (bridged to $channel)'
								} else {
									msg = msg + ' (not bridged. Use !bridge)'
								}
							}
							self.admin_say(msg)
							self.process_out_user(whoami)
						}
					}
				}
				'leave' {
					mut msg := '$whoami left room '
					if room := self.matrix.joined_rooms.find_room_by_id(room_id) {
						if room.name is string {
							msg = msg + room.name
						} else {
							msg = msg + '$room_id (found room, missing name)'
						}
					} else {
						msg = msg + '$room_id (unrecognized room)'
					}
					// self.admin_say(msg)
				}
				else {}
			}
		}
		'm.room.message' {
			event_id := cmd.data['event_id'].str()
			c := cmd.data['content'].as_map()
			body := c['body'].str()
			room_id := cmd.data['room_id'].str()
			sender := cmd.data['sender'].str()
			if sender != self.matrix.whoami {
				println('<- $sender ${c['msgtype']} $room_id $event_id "$body"')
				// if not a puppet matrix user
				if _ := self.matrix_name_match(sender) {
					println('msg is from matrix puppet ${sender}. skipping')
				} else {
					// if room has a human name
					if alias_room := self.matrix.joined_rooms.by_id(room_id) {
						irc_nick := self.name_convert(chat.System.matrix, sender)
						if alias_room.name is string {
							if alias_room.name.starts_with('@') {
								if body.starts_with('!') {
									self.command(chat.System.matrix, 'matrix', sender,
										room_id, body[1..])
								}
							} else {
								if room := bridge.matching_room(alias_room.name, mut self.db) {
									// repeat in irc
									saybody := match c['msgtype'].str() {
										'm.text' {
											body
										}
										'm.emote' {
											util.ctcp_encode('ACTION', body)
										}
										'm.image' {
											self.media_announcement(c)
										}
										else {
											'unknown matrix msgtype ${c['msgtype']}'
										}
									}
									room_parts := room.split(':')
									sayparts := saybody.split('\n')
									for saypart in sayparts {
										self.chat.say(chat.System.irc, irc_nick, room_parts[1],
											room_parts[0], saypart)
									}
								} else {
									println('as_do/m.room.message: no bridge found for ${alias_room}. msg dropped: $body')
								}
							}
						} else {
							println('warning: room_id $room_id is unrecognized. msg dropped: $body')
						}
					}
				}
			} else {
				println('$sender -> ${c['msgtype']} $room_id $event_id "$body"')
			}
		}
		else {
			println('unknown type')
		}
	}
}

fn (mut self Main) media_announcement(c map[string]json2.Any) string {
	// {"body":"IMG_20210704_154920.jpg","info":{"h":768,"mimetype":"image\/jpeg","size":163090,"w":1024},"msgtype":"m.image","url":"mxc:\/\/donp.org\/DBKlXYNItaxXzLDEgJwNdKBF"}
	media_url := self.matrix.mxc_to_url(c['url'].str())
	return util.ctcp_encode('ACTION', 'uploaded $media_url')
}

fn (mut self Main) command(system chat.System, network string, name string, room_id string, message string) {
	parts := message.trim_space().split(' ')
	println('COMMAND $system $network $name, $room_id $parts')
	match parts[0] {
		'help' {
			self.chat.say(system, '', network, room_id, 'commands: (each command gives its own help)')
			self.chat.say(system, '', network, room_id, '!status !irc !matrix !bridge')
		}
		'status' {
			self.status_report(system, network, room_id)
		}
		'matrix' {
			mut help_screen := false
			if parts.len > 1 {
				help_screen = self.command_matrix(system, network, room_id, parts)
			} else {
				help_screen = true
			}
			if help_screen {
				self.chat.say(system, '', network, room_id, '!matrix <status | join | leave>')
			}
		}
		'irc' {
			if parts.len > 1 {
				self.command_irc(system, name, network, room_id, parts)
			} else {
				self.chat.say(system, '', network, room_id, '!irc <add | status | delete | connect | join | part>')
			}
		}
		'bridge' {
			mut help_screen := false
			if parts.len > 1 {
				help_screen = self.command_bridge(system, network, room_id, parts)
			} else {
				help_screen = true
			}
			if help_screen {
				self.chat.say(system, '', network, room_id, '!bridge <add | list | del>')
			}
		}
		else {
			self.chat.say(system, '', network, room_id, 'unknown command ${parts[0]}. try !help')
		}
	}
}

fn (mut self Main) status_report(system chat.System, network string, room string) {
	mut msg := '$self.matrix.host is $self.matrix.conn_state in $self.matrix.joined_rooms.len() rooms. $self.irc.networks.networks.len irc networks connected.'
	self.chat.say(system, '', network, room, msg)
}

fn (mut self Main) matrix_status(system chat.System, network string, room string) {
	mut msg := '$self.matrix.host is $self.matrix.conn_state in $self.matrix.joined_rooms.len() rooms. '
	self.chat.say(system, '', network, room, msg)
	for r in self.matrix.joined_rooms.rooms {
		self.chat.say(system, '', network, room, 'matrix: room $r')
	}
}

fn (mut self Main) command_matrix(system chat.System, network string, room_id string, parts []string) bool {
	cmd := parts[1]
	match cmd {
		'status' {
			self.matrix_status(system, network, room_id)
		}
		'join' {
			if parts.len > 2 {
				room := parts[2]
				mut msg := ''
				if self.irc.is_room(room) {
				} else if self.matrix.is_room(room) {
					if alias_room := self.matrix.room_alias(room) {
						match self.join_request_matrix(room, alias_room.id) {
							.saved {
								msg = 'matrix room $room ($alias_room.id) added'
								go self.sync_matrix_rooms()
							}
							.already_joined {
								msg = 'matrix room $room already added'
							}
						}
					} else {
						match err {
							matrix.RoomAliasErrNotFound {
								msg = 'join failed: no room_alias exists for ${room}.'
							}
							else {
								msg = 'join failed: room_alias failure: ($err)'
							}
						}
					}
				} else {
					msg = 'join: unknown room format: $room'
				}
				self.chat.say(system, '', network, room_id, msg)
			} else {
				help_msg := '!join <#<irc_channel_name>[:<irc_server_hostname>] | #<matrix_room:server.com>>'
				self.chat.say(system, '', network, room_id, help_msg)
				self.chat.say(system, '', network, room_id, 'exmaple: !join #chatirc')
				self.chat.say(system, '', network, room_id, 'exmaple: !join #chat:matrix.org')
			}
		}
		'leave' {
			if parts.len > 2 {
				room := parts[2]
				mut msg := ''
				if self.irc.is_room(room) {
					self.leave_request(chat.System.irc, network, room)
					msg = 'irc room $room removed'
				} else if self.matrix.is_room(room) {
					if alias_room := self.matrix.room_alias(room) {
						self.leave_request(chat.System.matrix, network, alias_room.id)
						msg = 'matrix room $alias_room removed'
					} else {
						match err {
							matrix.RoomAliasErrNotFound {}
							else {}
						}
					}
				} else {
					msg = 'leave: unknown room format: $room'
				}
				self.chat.say(system, '', network, room_id, msg)
				go self.sync_matrix_rooms()
			} else {
				self.chat.say(system, '', network, room_id, '!leave <#ircchannel or #matrix:room>')
			}
		}
		else {
			return true
		}
	}
	return false
}

fn (mut self Main) command_bridge(system chat.System, network string, room_id string, parts []string) bool {
	if parts.len > 1 {
		cmd := parts[1]
		match cmd {
			'list' {
				rows := self.db.select_all('bridge_rooms')
				for row in rows {
					self.chat.say(system, '', network, room_id, 'bridge ${row[0]} <=> ${row[1]}')
				}
			}
			'add' {
				if parts.len == 4 {
					left := parts[2]
					right := parts[3]
					matrix_server := left.split(':')[1]
					if matrix_server == self.config.matrix_host {
						irc_netname := right.split(':')[1]
						if _ := self.irc.networks.by_name(irc_netname) {
							bridge := bridge.Bridge{
								left: left
								right: right
							}
							self.db.insert('bridge_rooms', bridge.to_db())
						} else {
							self.chat.say(system, '', network, room_id, '$irc_netname is not a known irc network. use !irc add')
						}
					} else {
						self.chat.say(system, '', network, room_id, '$left must be a channel on $self.config.matrix_host')
					}
				} else {
					self.chat.say(system, '', network, room_id, '!bridge add #room:matrix.server #channel:ircnetwork')
				}
			}
			'del' {
				if parts.len == 3 {
					self.db.delete_by_field('bridge_rooms', 'left', parts[2])
					self.db.delete_by_field('bridge_rooms', 'right', parts[2])
				}
			}
			else {
				return true
			}
		}
		return false
	} else {
		return true
	}
}

fn (mut self Main) command_irc(system chat.System, name string, network string, room_id string, parts []string) bool {
	mut default_action := false
	match parts[1] {
		'add' {
			if parts.len == 4 {
				host := parts[2]
				nick := parts[3]
				mut irc_temp := irc.Network{
					hostname: host
					nick: nick
				}
				self.db.insert('irc_servers', irc.network_to_db(irc_temp))
				self.chat.say(system, '', network, room_id, 'host $host nick $nick added')
				//  << copies ircnet, so find after add
				mut new_ircnet := self.irc.networks.add(irc_temp)
				mut bot_puppet := self.irc.new_ghost(mut new_ircnet, new_ircnet.nick)
				go bot_puppet.dial()
			} else {
				self.chat.say(system, '', network, room_id, 'usage: !irc add <host:port> <bridge nickname>')
			}
		}
		'del' {
			if ircnet := self.irc.networks.by_name(parts[2]) {
				// VBUG if mut var :=
				mut p_net := *ircnet
				self.db.delete_by_field('irc_servers', 'hostname', p_net.hostname)
				ircidx := self.irc.networks.by_hostname_idx(p_net.hostname)
				if ircidx >= 0 {
					mut puppets := self.irc.puppets.by_network(p_net.name)
					for mut puppet in puppets {
						puppet.hangup()
					}
					self.irc.networks.networks.delete(ircidx)
				}
			} else {
				println('server del $parts[2] not found')
			}
		}
		'status' {
			for mut ircnet in self.irc.networks.networks {
				mut p_net := *ircnet
				self.chat.say(system, '', network, room_id, 'irc: network: $p_net')
				for mut puppet in self.irc.puppets.puppets {
					mut p_p := *puppet
					msg2 := '$p_net $p_p.nick $p_p.state $p_p.channels.channels.len channels'
					self.chat.say(system, '', network, room_id, 'irc: $msg2')
					for channel in p_p.channels.channels {
						msg3 := '$p_net $channel $p_p.nick'
						self.chat.say(system, '', network, room_id, 'irc: $msg3')
					}
				}
			}
		}
		'nick' {
			if parts.len > 2 {
				if parts.len == 3 {
					nick := parts[2]
					old_nick := self.name_convert(chat.System.matrix, name)
					mut alias := self.aliases.match_matrix(name) or {
						alias := &chat.Alias{
							matrix: name
							irc: nick
						}
						self.db.insert('bridge_nicks', chat.alias_to_db(alias))
						self.aliases.add(alias)
						alias
					}
					if alias.irc != nick {
						self.chat.say(system, '', network, room_id, 'updated preferred irc nick for $name from $alias.irc to $nick')
						alias.irc = nick
						self.db.update_by_field('bridge_nicks', 'matrix', name, 'irc',
							nick)
					}
					mut puppet := self.irc.puppets.by_nick(alias.irc) or {
						d_msg := 'nick $alias.irc not found'
						self.chat.say(system, '', network, room_id, d_msg)
						return false
					}
					d_msg := 'nicksync $alias.irc == $puppet.nick'
					self.chat.say(system, '', network, room_id, d_msg)
					if old_nick == puppet.nick {
						msg := 'changing $puppet.network $puppet.nick to $nick'
						self.chat.say(system, '', network, room_id, msg)
						puppet.nick(nick)
					}
				} else {
					msg := '!irc nick <new_nick>'
					self.chat.say(system, '', network, room_id, msg)
				}
			} else {
				mut p_msg := ''
				nick := self.name_convert(chat.System.matrix, name)
				p_msg = 'your ($name) preferred nick is $nick'
				self.chat.say(system, '', network, room_id, p_msg)
				for ircnet in self.irc.networks.networks {
					puppets := self.irc.puppets.by_network(ircnet.name)
					for puppet in puppets {
						p_msg = '$ircnet $puppet.nick'
						self.chat.say(system, '', network, room_id, p_msg)
					}
				}
			}
		}
		'connect' {
			for mut puppet in self.irc.puppets.puppets {
				mut p_pup := *puppet
				mut msg := 'checking irc connection for $p_pup.nick'
				self.chat.say(system, '', network, room_id, msg)
				if p_pup.state == .disconnected {
					msg = '$p_pup.nick disconnected. reconnecting to $p_pup.network'
					self.chat.say(system, '', network, room_id, msg)
					p_pup.dial()
					println('command_irc connect p_pup.state $p_pup.state')
					if p_pup.state == .connected {
						self.irc.comm(mut p_pup)
						p_pup.signin()
					}
				}
			}
		}
		'join' {
			if parts.len == 4 {
				mut msg := ''
				network_name := parts[2]
				room := parts[3]
				if join_network := self.irc.networks.by_name(network_name) {
					match self.join_request_irc(join_network.name, room) {
						.saved {
							msg = 'irc room $room added'
							irc_nick := self.name_convert(system, name)
							if ghost := self.irc.puppets.by_net_nick(join_network, irc_nick) {
								msg = msg + '(joining)'
								// vbug to use go self.sync_irc_channels
								self.sync_irc_channels(ghost)
							} else {
								msg = msg +
									'($irc_nick not currently connected to $join_network.name)'
							}
						}
						.already_joined {
							msg = 'irc room $room already added'
						}
					}
				} else {
					msg = 'no network named ${network_name}. use !irc list'
				}
				self.chat.say(system, '', network, room_id, msg)
			} else {
				self.chat.say(system, '', network, room_id, 'usage: !irc join <network name> <#channel>')
			}
		}
		'part' {
			if parts.len == 4 {
				mut msg := ''
				network_name := parts[2]
				room := parts[3]
				if join_network := self.irc.networks.by_name(network_name) {
					self.leave_request(chat.System.irc, join_network.name, room)
					msg = 'irc room $room $join_network.name removed'
				} else {
					msg = 'no network named ${network_name}. use !irc list'
				}
				self.chat.say(system, '', network, room_id, msg)
			} else {
				self.chat.say(system, '', network, room_id, 'usage: !irc join <network name> <#channel>')
			}
		}
		else {
			default_action = true
		}
	}
	return default_action
}

fn (mut self Main) listen_out() {
	for {
		select {
			outmsg := <-self.chat.out {
				self.process_out(outmsg)
			}
			1 * time.minute {
				if next_id := self.chat.queue.next_id() {
					println('listen_out timed out, found a msg.')
					self.process_out(next_id)
				}
			}
		}
	}
}

fn (mut self Main) process_out_user(user string) {
	println('process_out_user looking for $user')
	ids := self.chat.queue.by_name(user)
	for idx, id in ids {
		println('process_out_user found $user $id $idx/$ids.len')
		self.chat.out <- id
		break
	}
}

fn (mut self Main) process_out(id string) {
	if self.chat.queue.contains(id) {
		outmsg := self.chat.queue.get(id)
		println('process_out [$id/$self.chat.queue.len()] $outmsg')
		match outmsg.system {
			.irc {
				// TOOD remove
				ircnet_name := if outmsg.network.len == 0 {
					if self.irc.networks.networks.len > 0 {
						self.irc.networks.networks.first().hostname
					} else {
						'noname'
					}
				} else {
					outmsg.network
				}
				match self.irc.say(ircnet_name, outmsg.name, outmsg.room, outmsg.message) {
					.good {
						println('process_out queue.delete($id)')
						self.chat.queue.delete(id)
					}
					.network_not_found {}
					.user_not_found {
						self.chat.cin <- chat.Payload(chat.MakeIrcUser{
							network_hostname: ircnet_name
							nick: outmsg.name
						})
					}
					.error {}
				}
			}
			.matrix {
				if room := self.matrix.joined_rooms.find_room_by_id(outmsg.room) {
					if self.matrix.owner == outmsg.name {
						self.matrix.room_say(room, outmsg.message)
					} else {
						match self.matrix.room_say_as(outmsg.name, room, outmsg.message) {
							.good {
								self.chat.queue.delete(id)
								if self.chat.queue.len() > 0 {
									println('process_out finished ${id}. remaining queue len $self.chat.queue.len()')
								}
							}
							.user_not_found {
								nick := self.name_convert(chat.System.matrix, outmsg.name)
								self.matrix.cin <- matrix.Payload(matrix.MakeUser{
									name: nick
									user_id: outmsg.name
								})
							}
							.not_in_room {
								p := matrix.Payload(matrix.JoinRoom{
									name: outmsg.name
									room: outmsg.room
								})
								match self.matrix.cin.try_push(p) {
									.success {}
									.not_ready { println('WARNING matrix.cin channel not ready. $self.matrix.cin.len entries') }
									.closed {}
								}
							}
							.error {
								println('matrix room_say_as error. retainig msg for retransmission')
							}
						}
					}
				} else {
					println('listen_out matrix.joined_rooms.find_room_by_id failed: $err.msg dropped: $outmsg.message ')
					println('process_out queue.delete($id)')
					self.chat.queue.delete(id)
				}
			}
		}
	} else {
		println('procesS_out dropping $id not in queue (len $self.chat.queue.len()')
	}
}

pub fn (mut self Main) leave_request(system chat.System, network string, room string) {
	table, field := match system {
		.irc {
			'irc_channels', 'channel'
		}
		.matrix {
			'matrix_rooms', 'room_id'
		}
	}
	self.db.delete_by_field(table, field, room)
}

enum JoinRequestResults {
	saved
	already_joined
}

pub fn (mut self Main) join_request_irc(network string, channel string) JoinRequestResults {
	self.db.insert('irc_channels', [
		db.SqlValue{ name: 'channel', value: channel },
		db.SqlValue{
			name: 'netname'
			value: network
		},
	])
	return JoinRequestResults.saved
}

pub fn (mut self Main) join_request_matrix(name string, room_id string) JoinRequestResults {
	self.db.insert('matrix_rooms', [db.SqlValue{ name: 'room_id', value: room_id },
		db.SqlValue{
			name: 'name'
			value: name
		},
	])
	return JoinRequestResults.saved
}

pub fn (mut self Main) sync_matrix_rooms() {
	println('= sync_rooms')
	db_rooms := self.db.select_all('matrix_rooms').map(matrix.room_from_db(it))
	println('sync_rooms: matrix db_rooms $db_rooms')
	println('sync_rooms: matrix joined_rooms $self.matrix.joined_rooms')
	needs_to_join := matrix.rooms_subtract(db_rooms, self.matrix.joined_rooms.pointers())
	println('sync_rooms: matrix needs_to_join $needs_to_join')
	for room in needs_to_join {
		println('sync_rooms: joining $room.id')
		_, code := self.matrix.join(room.id) or {
			println('matrix.join fail $err')
			continue
		}
		if code == 200 {
			self.matrix.joined_rooms.add(room)
			self.admin_say('matrix: room $room joined')
		} else if code == 403 {
			println('sync_rooms: not invited to $room')
			self.leave_request(chat.System.matrix, '', room.id)
		}
	}
	for mut room in self.matrix.joined_rooms.rooms {
		if room.user_ids.len == 0 {
			room.user_ids = self.matrix.room_joined_members(room.id) or { continue }
			if room.name is string {
				if room.name.starts_with('@') {
					mut present := false
					for user_id in room.user_ids {
						if user_id == room.name {
							present = true
						}
					}
					if present == false {
						println('warning! $room does not include ${room.name}. sending invite.')
						self.matrix.room_invite(room, room.name) or {}
					}
				}
			}
		}
	}
	needs_to_leave := matrix.rooms_subtract(self.matrix.joined_rooms.pointers(), db_rooms)
	println('sync_rooms: matrix needs_to_leave $needs_to_leave')
	for room in needs_to_leave {
		self.matrix.leave(room.id)
	}
}

pub fn (mut self Main) sync_irc_channels(puppet irc.Puppet) {
	for row in self.db.select_all('irc_channels') {
		channel := row[0]
		netname := row[1]
		if puppet.network.name == netname {
			if puppet.state == .connected {
				if _ := puppet.find_channel(channel) {
					println('$puppet.network $puppet $channel already connected')
				} else {
					println('sync_irc_channels() $puppet.network $puppet.nick joining $netname $channel from db')
					mut puppet_mut := self.irc.puppets.by_nick(puppet.nick) or { continue }
					puppet_mut.join(channel)
				}
			} else {
				println('sync_irc_channels() $puppet.network $puppet.nick not connected. cannot join $channel')
			}
		}
	}
}

pub fn (mut self Main) matrix_name_match(name string) ?string {
	restr := '@$self.config.matrix_regex:$self.config.matrix_host'
	return regex_name_match(restr, name)
}

pub fn (mut self Main) irc_name_match(name string) bool {
	restr := self.config.irc_regex
	if rmatch := regex_name_match(restr, name) {
		println('irc_name_match $restr $name => $rmatch')
		return true
	} else {
		return false
	}
}

pub fn regex_name_match(restr string, name string) ?string {
	restr2 := restr.replace('|', '\\|') // pipe char helper hack
	mut re := regex.regex_opt(restr2) or { panic('regex_name_match regex parse fail for $restr') }
	_, _ := re.find(name)
	groups := re.get_group_list()
	group := groups[0] // always 1 group
	if group.end > 1 {
		return name[group.start..group.end]
	} else {
		return error('regex_name_match failed for $restr on $name')
	}
}

pub fn (mut self Main) name_convert(from_network chat.System, name string) string {
	return match from_network {
		.irc {
			alias := self.aliases.match_irc(name) or {
				matrix_user := regex_self_replace(self.config.matrix_regex, name)
				matrix_id := matrix.join([matrix_user, self.config.matrix_host])
				alias := &chat.Alias{
					matrix: matrix_id
					irc: name
				}
				self.matrix.user_displayname(matrix_id, name) or {
					println('ignoring user_displayname error for $matrix_id to $name')
				}
				self.aliases.add(alias)
				alias
			}
			alias.matrix
		}
		.matrix {
			alias := self.aliases.match_matrix(name) or {
				matrix_user := matrix.split(name)[1]
				irc_nick := regex_self_replace(self.config.irc_regex, matrix_user)
				alias := &chat.Alias{
					matrix: name
					irc: irc_nick
				}
				// self.aliases.add(alias)
				alias
			}
			alias.irc
		}
	}
}

pub fn regex_self_replace(restr string, name string) string {
	newname := restr.replace_once('\(\.\*\)', name)
	println('regex_self_replace $restr $name => $newname')
	return newname
}

fn (mut self Main) nearest_matrix_channel(room_name string) ?string {
	if mroom := self.matrix.joined_rooms.room_by_partial_name(room_name.before(':')) {
		return mroom.id
	} else {
		return error('matchingmatrixchannelfail')
	}
}

fn (mut self Main) nearest_irc_channel(nick string, room &matrix.Room) ?string {
	if room.name is string { // VBUG: name := room.name {
		matrix_partial_name := room.name.before(':')
		println('matching_irc_channel matrix room name $room.name as irc channel name $matrix_partial_name')

		mut sname := ''
		// db search
		rows := self.db.select_by_field('irc_channels', 'channel', matrix_partial_name)
		if rows.len > 0 {
			println('matching_irc_channel found $matrix_partial_name in irc_channels db')
			sname = rows[0][0]
		} else {
			//  connected channels search
			if ircc := self.irc.find_channel_by_name(nick, matrix_partial_name) {
				sname = ircc.name
			} else {
				return error('warning: matching_irc_channel found no irc channel for nick $nick matrix_room $matrix_partial_name')
			}
		}
		return sname
	} else {
		return error('matching_irc_channel: giving up on room $room has no name')
	}
}

pub fn (mut self Main) admin_say(msg string) {
	println('admin_say: $msg')
	if self.config.admin_room.len > 0 {
		if room := self.matrix.joined_rooms.find_room_by_name(self.config.admin_room) {
			self.chat.say(chat.System.matrix, '', self.config.matrix_host, room.id, msg)
		} else {
			println('warning admin_say has no room ${self.config.admin_room}. dropping msg $msg')
		}
	} else {
		self.matrix_say(self.config.matrix_owner, msg)
	}
}

pub fn (mut self Main) matrix_say(user string, msg string) {
	mut room := matrix.Room{}
	user_id := if user == self.matrix.whoami { self.config.matrix_owner } else { user }
	if this_room := self.matrix.joined_rooms.dm(user_id) {
		room = this_room
	} else {
		println('warning main.matrix_say has no private room with ${user_id}. creating room')
		room = self.matrix.room_create(user_id) or {
			println('main.matrix_say create_room $user_id failed. $err')
			return
		}
		println('warning main.matrix_say created room ${room}. inviting $user_id')
		self.matrix.room_invite(room, user_id) or {
			println('main.matrix_say invite $room $user_id failed. $err')
			return
		}
	}
	self.chat.say(chat.System.matrix, '', self.config.matrix_host, room.id, msg)
}
