module chat

import setup
import rand
import msg
import db

type Payload = MakeIrcUser | MakeMatrixUser

pub struct MakeIrcUser {
pub:
	network_hostname string
	nick             string
}

pub struct MakeMatrixUser {}

pub struct Aliases {
mut:
	aliases []&Alias
}

[heap]
pub struct Alias {
pub mut:
	matrix string
	irc    string
}

pub struct Actor {
pub mut:
	queue Queue
	out   chan string
	cin   chan Payload
}

pub struct Queue {
pub mut:
	entries map[string]Say
}

pub enum System {
	irc
	matrix
}

type SayMsg = msg.IrcMsg | msg.MatrixMsg

pub struct Say {
pub:
	system  System
	network string
	name    string
	room    string
	message string
}

pub fn (self Say) str() string {
	return '>$self.system< name: "$self.name" room: "$self.room" msg: "$self.message"'
}

pub fn setup(config setup.Config) &Actor {
	return &Actor{
		out: chan string{cap: 100}
		cin: chan Payload{cap: 100}
	}
}

pub fn make_id() string {
	return rand.string(5)
}

pub fn (mut self Actor) say(chat System, name string, network string, room string, message string) {
	msg := Say{
		system: chat
		network: network
		name: name
		room: room
		message: message
	}
	id := make_id()
	self.queue.set(id, msg)
	println('chat.say [$id/$self.queue.entries.len] $msg')
	match self.out.try_push(id) {
		.success {}
		.not_ready { println('WARNING chat.out channel not ready. channel len $self.out.len') }
		.closed {}
	}
}

pub fn (mut self Queue) set(id string, msg Say) {
	self.entries[id] = msg
}

pub fn (mut self Queue) get(id string) Say {
	return self.entries[id]
}

pub fn (mut self Queue) len() int {
	return self.entries.len
}

pub fn (mut self Queue) delete(id string) {
	self.entries.delete(id)
}

pub fn (mut self Queue) next() ?Say {
	id := self.next_id() ?
	return self.entries[id]
}

pub fn (mut self Queue) next_id() ?string {
	if self.entries.len > 0 {
		return self.entries.keys()[0]
	} else {
		return error('empty')
	}
}

pub fn (mut self Queue) contains(name string) bool {
	return self.entries.keys().contains(name)
}

pub fn (mut self Queue) by_name(name string) []string {
	mut ids := []string{}
	for id, entry in self.entries {
		if entry.name == name {
			ids << id
		}
	}
	return ids
}

pub fn (mut self Aliases) match_irc(nick string) ?&Alias {
	for alias in self.aliases {
		if alias.irc == nick {
			println('chat.Aliases.match_irc $nick found $alias')
			return alias
		}
	}
	return error('not found')
}

pub fn (mut self Aliases) match_matrix(nick string) ?&Alias {
	for alias in self.aliases {
		if alias.matrix == nick {
			println('chat.Aliases.match_matrix $nick found $alias')
			return alias
		}
	}
	return error('not found')
}

pub fn (mut self Aliases) add(alias &Alias) &Alias {
	println('chat.Aliases.add $alias')
	self.aliases.prepend(alias)
	return self.aliases[0]
}

pub fn (mut self Alias) str() string {
	return 'matrix:$self.matrix irc:$self.irc'
}

pub fn alias_to_db(obj Alias) []db.SqlValue {
	mut row := []db.SqlValue{}
	row << db.SqlValue{
		name: 'matrix'
		value: db.SqlType(obj.matrix)
	}
	row << db.SqlValue{
		name: 'irc'
		value: db.SqlType(obj.irc)
	}
	return row
}
