module matrix

import x.json2
import net
import net.http
import net.urllib
import setup
import rand
import regex
import time
import util

enum ConnState {
	disconnected
	connected
}

type Payload = Connect | Disconnect | JoinRoom | MakeUser

struct Connect {}

struct Disconnect {}

pub struct MakeUser {
pub:
	user_id string
	name    string
}

pub fn (self MakeUser) str() string {
	return '$self.user_id ($self.name)'
}

pub struct JoinRoom {
pub:
	name string
	room string
}

struct Actor {
pub:
	out   chan Say
	cin   chan Payload
	host  string
	token string
	owner string
pub mut:
	conn_state   ConnState
	last_say     time.Time
	joined_rooms Rooms
	whoami       string
}

struct Rooms {
pub mut:
	rooms []Room
}

[heap]
pub struct Room {
pub:
	id   string
	name util.StringOrNone
pub mut:
	user_ids []string
}

pub struct Say {
pub:
	room    Room
	message string
}

pub struct SayContext {
pub:
	room_id string
	say     chan Say
}

pub fn init(config setup.Config) &Actor {
	mut self := &Actor{
		out: chan Say{}
		cin: chan Payload{cap: 100}
		host: config.matrix_host
		token: config.as_token
		owner: config.matrix_owner
		last_say: time.now()
	}
	return self
}

pub fn (mut self Actor) setup() {
	if matrix_id := self.whoami() {
		self.whoami = matrix_id
		makeuser := MakeUser{
			user_id: matrix_id
			name: split(matrix_id)[1]
		}
		self.register(makeuser) or {}
		self.user_presence(matrix_id, 'online') or {}
		self.conn_state = ConnState.connected
		self.cin <- Payload(Connect{})
	} else {
		println('matrix setup failed. please verify the matrix_host and as_token in config.json')
	}
}

pub fn room_from_db(cols []string) &Room {
	return &Room{
		id: cols[0]
		name: util.StringOrNone(cols[1])
	}
}

pub fn rooms_subtract(rooms_a []&Room, rooms_b []&Room) []&Room {
	mut missing := []&Room{}
	for room in rooms_a {
		if rooms_contains(rooms_b, room) {
		} else {
			missing << room
		}
	}
	return missing
}

pub fn rooms_contains(rooms []&Room, looking Room) bool {
	for room in rooms {
		if room.id == looking.id {
			return true
		}
	}
	return false
}

pub fn (mut self Actor) listen() {
}

pub fn (mut self Actor) mxc_to_url(mxc string) string {
	servername, mediaid := mxc_split(mxc)
	url := 'https://$self.host/_matrix/media/r0/download/$servername/$mediaid'
	return url
}

pub fn mxc_split(mxc string) (string, string) {
	// "mxc:\/\/donp.org\/DBKlXYNItaxXzLDEgJwNdKBF"
	mxc_regex := r'mxc://([^/]+)/([^/]+)'
	mut re := regex.regex_opt(mxc_regex) or { panic(err) }
	re.match_string(mxc)
	mut parts := []string{}
	for g_index := 0; g_index < re.group_count; g_index++ {
		start, end := re.get_group_bounds_by_id(g_index)
		if start >= 0 {
			parts << mxc[start..end]
		}
	}
	return parts[0], parts[1]
}

pub fn (mut self Actor) try_pause() {
	duration := time.now() - self.last_say
	if duration.milliseconds() < 100 {
		println('matrix.say 500ms pause (last call was ${duration.milliseconds()}ms ago)')
		time.sleep(500 * time.millisecond)
	}
	self.last_say = time.now()
}

pub fn (mut self Actor) call_get(api string) ?(map[string]json2.Any, int) {
	return self.call(http.Method.get, api, '')
}

pub fn (mut self Actor) call(method http.Method, api string, body string) ?(map[string]json2.Any, int) {
	// try_pause()
	mut config := http.FetchConfig{
		method: method
		data: body
	}
	header := http.new_header(key: .authorization, value: 'Bearer $self.token')
	url := 'https://$self.host/_matrix/client/r0/$api'
	resp := http.fetch(method: method, data: body, url: url, header: header) or { return error('$url $err') }
	println('$method $url $config.data => [$resp.status_code] $resp.text')
	any := json2.raw_decode(resp.text) ?
	return any.as_map(), resp.status_code
}

pub fn (mut self Actor) whoami() ?string {
	kv, _ := self.call_get('account/whoami') or {
		println('whoami fail $err')
		return error('z')
	}
	return kv['user_id'] as string
}

pub fn split(id string) []string {
	mut parts := []string{}
	parts << id.substr(0, 1)
	left := id.substr(1, id.len)
	parts << left.before(':')
	parts << left.after(':')
	return parts
}

pub fn join(parts []string) string {
	return '@' + parts[0] + ':' + parts[1]
}

pub fn (mut self Actor) register(user MakeUser) ?string {
	mut user_data := map[string]json2.Any{}
	username := split(user.user_id)[1]
	user_data['username'] = username
	user_data['type'] = 'm.login.application_service'
	kv, _ := self.call(http.Method.post, 'register', user_data.str()) ?
	if 'errcode' in kv {
		return error('matrix.register() error! $kv')
	} else {
		user_id := kv['user_id'] as string
		self.user_displayname(user_id, user.name) or { println('ERR: $err') }
		return user_id
	}
}

pub fn (mut self Actor) sync() string {
	self.call_get('sync') or {}
	return ''
}

pub fn (mut self Actor) sync_user(user_id string) string {
	self.call_get('sync?user_id=$user_id') or {}
	return ''
}

pub fn (mut self Actor) joined_rooms() ?[]string {
	resp, _ := self.call_get('joined_rooms') ?
	return resp['joined_rooms'].arr().map(it.str())
}

pub fn (mut self Actor) join(room_id string) ?(map[string]json2.Any, int) {
	return self.join_as('', room_id)
}

pub fn (mut self Actor) join_as(user_id string, room_id string) ?(map[string]json2.Any, int) {
	user_part := if user_id.len > 0 { '?user_id=$user_id' } else { '' }
	return self.call(http.Method.post, 'rooms/$room_id/join$user_part', '')
}

pub fn (mut self Actor) leave(room_id string) {
	params, code := self.room_leave(room_id) or { return }
	println('matrix.leave $code $params')
	match code {
		200 {
			self.joined_rooms.delete(room_id)
		}
		404 {
			if params['errcode'].str() == 'M_UNKNOWN' {
				self.joined_rooms.delete(room_id)
			}
		}
		else {}
	}
}

pub fn (mut self Actor) room_leave(room_id string) ?(map[string]json2.Any, int) {
	return self.call(http.Method.post, 'rooms/$room_id/leave', '')
}

// not implemented in synapse until 1.36 (api r0.6.1)
pub fn (mut self Actor) room_aliases(room_id string) ?[]string {
	params, _ := self.call_get('rooms/$room_id/aliases') ?
	return params['aliases'].arr().map(it.str())
}

pub fn (mut self Actor) room_joined_members(room_id string) ?[]string {
	mut members := []string{}
	params, code := self.call_get('rooms/$room_id/joined_members') or { return err }
	if code == 200 {
		for k, _ in params['joined'].as_map() {
			members << k
		}
	}
	return members
}

pub fn (mut self Actor) room_create(room_alias string) ?&Room {
	mut user_data := map[string]json2.Any{}
	user_data['room_alias_name'] = room_alias
	user_data['is_direct'] = true
	params, code := self.call(http.Method.post, 'createRoom', user_data.str()) or { return err }
	if code == 200 {
		room := &Room{
			id: params['room_id'].str()
			name: room_alias
		}
		return room
	} else {
		return error('code $code')
	}
}

pub fn (mut self Actor) room_state(room_id string) ?string {
	self.call_get('rooms/$room_id/state') ?
	return ''
}

pub fn (mut self Actor) room_messages(room Room) string {
	self.call_get('rooms/$room.id/messages') or {}
	return ''
}

pub fn (mut self Actor) room_say(room Room, msg string) string {
	self.room_say_as('', room, msg)
	return ''
}

pub fn (mut self Actor) room_invite(room Room, user string) ?bool {
	mut user_data := map[string]json2.Any{}
	user_data['user_id'] = user
	self.call(http.Method.post, 'rooms/$room.id/invite', user_data.str()) or { return err }
	return true
}

pub enum RoomSayAsReturn {
	good
	user_not_found
	not_in_room
	error
}

pub fn (mut self Actor) room_say_as(user_id string, room Room, msg string) RoomSayAsReturn {
	id := rand.string(6)
	mut evt := map[string]json2.Any{}
	if ctcp_msg := util.ctcp_decode(msg) {
		evt['msgtype'] = 'm.emote'
		evt['body'] = ctcp_msg.split(' ')[1..].join(' ')
	} else {
		evt['msgtype'] = 'm.text'
		evt['body'] = msg
	}
	user_part := if user_id.len > 0 { '?user_id=$user_id' } else { '' }
	resp, code := self.call(http.Method.put, 'rooms/$room.id/send/m.room.message/$id$user_part',
		evt.str()) or {
		println(err)
		return RoomSayAsReturn.error
	}
	if code == 403 {
		error := resp['error'].str()
		//{"errcode":"M_FORBIDDEN","error":"Application service has not registered this user"}
		if error.contains('has not registered') {
			return RoomSayAsReturn.user_not_found
		} else if error.contains('not in room') {
			//{"errcode":"M_FORBIDDEN","error":"User @ircbr_dpdp144:donp.org not in room !FMIqCsoGJDbtjiBptb:donp.org (None)"}
			return RoomSayAsReturn.not_in_room
		}
	}
	return RoomSayAsReturn.good
}

pub fn (mut self Actor) user_presence(user_id string, status string) ?string {
	mut evt := map[string]json2.Any{}
	evt['presence'] = status
	self.call(http.Method.put, 'presence/$user_id/status', evt.str()) ?
	return ''
}

pub fn (mut self Actor) user_display_name(user_id string) ?string {
	escaped_user_id := urllib.path_escape(user_id)
	url := 'profile/$escaped_user_id/displayname?user_id=$escaped_user_id'
	params, _ := self.call_get(url) ?
	displayname := params['displayname'].str()
	return displayname
}

pub fn (mut self Actor) user_displayname(user_id string, displayname string) ?bool {
	mut name_data := map[string]json2.Any{}
	escaped_user_id := urllib.path_escape(user_id)
	url := 'profile/$escaped_user_id/displayname?user_id=$escaped_user_id'
	name_data['displayname'] = displayname
	_, status := self.call(http.Method.put, url, name_data.str()) ?
	return status == 200
}

struct RoomAliasErrNotFound {
pub: // look like IError
	msg  string
	code int
}

pub fn (mut self Actor) room_alias(room_alias string) ?&Room {
	if room_alias.starts_with('#') {
		ret, code := self.call_get('directory/room/' + urllib.path_escape(room_alias)) ?
		if code == 404 {
			return IError(&RoomAliasErrNotFound{})
		} else {
			return &Room{
				name: room_alias
				id: ret['room_id'].str()
			}
		}
	} else {
		return error('$room_alias is not a room_alias')
	}
}

pub fn (self Actor) is_room(room string) bool {
	//#veloren:matrix.org
	room_match := r'^[!#].*:.*$'
	mut re := regex.regex_opt(room_match) or { panic('regex fail') }
	start, _ := re.match_string(room)
	return start > -1
}

pub fn (self Actor) invited_by(data map[string]json2.Any) string {
	mut alias := ''
	for s in data['invite_room_state'].arr() {
		state := s.as_map()
		mtype := state['type'].str()
		println('invite_by checking type $mtype in $state')
		if mtype == 'm.room.canonical_alias' {
			alias = state['content'].as_map()['alias'].str()
			println('invited by room $alias')
		}
		if mtype == 'm.room.member' {
			if alias.len == 0 {
				alias = state['sender'].str()
				println('invited by user $alias')
			}
		}
	}
	if alias.len == 0 {
		println('invite_by: warning no inviter found')
	}
	return alias
}

pub fn (mut self Rooms) replace(rooms []&Room) {
	self.rooms.clear()
	// VBUG self.rooms << rooms
	for r in rooms {
		self.rooms << r
	}
}

pub fn (mut self Rooms) add(room Room) {
	self.rooms << room
}

pub fn (mut self Rooms) delete(room_id string) {
	if idx := self.find_idx_by_id(room_id) {
		self.rooms.delete(idx)
		println('rooms.delete() $room_id')
	} else {
		println('rooms.delete() $room_id $err')
	}
}

pub fn (mut self Rooms) find_idx_by_id(room_id string) ?int {
	for idx, room in self.rooms {
		if room.id == room_id {
			return idx
		}
	}
	return error('not found')
}

pub fn (mut self Rooms) len() int {
	return self.rooms.len
}

pub fn (mut self Rooms) dm(user string) ?Room {
	return self.find_room_by_name(user)
}

pub fn (mut self Rooms) find_room_by_name(name string) ?Room {
	for room in self.rooms {
		if room.name is string { // VBUG room_name := room.name {
			if room.name == name {
				return room
			}
		}
	}
	return error("room name \"$name\" not found")
}

pub fn (mut self Rooms) find_room_by_id(room_id string) ?Room {
	for room in self.rooms {
		if room.id == room_id {
			return room
		}
	}
	return error("room \"$room_id\" not found")
}

pub fn (mut self Rooms) room_by_partial_name(room_name string) ?&Room {
	println('room_name_by_partial_name: searching $room_name in $self.rooms.len rooms')
	for mut room in self.rooms {
		if room.name is string { // this_room_name := room.name {
			partial_name := room.name.before(':')
			println('room_name comparing $partial_name to $room_name')
			if partial_name == room_name {
				return room
			}
		}
	}
	return error('room_partial_name not in room list')
}

pub fn (mut self Rooms) by_id(room_id string) ?&Room {
	for mut room in self.rooms {
		if room.id == room_id {
			return room
		}
	}
	return error('$room_id not in room list')
}

pub fn (self Rooms) pointers() []&Room {
	mut ptrs := []&Room{}
	for mut room in self.rooms {
		ptrs << room
	}
	return ptrs
}

pub fn (self Rooms) str() string {
	return self.rooms.str()
}

pub fn (self Room) str() string {
	name := if self.name is string { self.name } else { 'None' }
	return '"$name"($self.id)'
}
