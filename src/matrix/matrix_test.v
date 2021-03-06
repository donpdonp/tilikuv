module matrix

import setup
import x.json2
import os

fn test_is_room() {
	config := setup.Config{}
	m := init(config)
	assert m.is_room('#roomname:server.com')
	assert m.is_room('!roomid:server.com')
	assert m.is_room('#ircroom') == false
}

fn test_split() {
	parts := split('@user:server.com')
	assert parts[0] == '@'
	assert parts[1] == 'user'
	assert parts[2] == 'server.com'
}

fn test_invite_by() {
	config := setup.Config{}
	m := init(config)
	if json_str := os.read_file('src/matrix/invite_room.json') {
		matrix_invite := json2.raw_decode(json_str) or { panic('') }.as_map()
		assert m.invited_by(matrix_invite) == '#roomy-room:donp.org'
	} else {
		assert false
	}
	if json_str := os.read_file('src/matrix/invite_pm.json') {
		matrix_invite := json2.raw_decode(json_str) or { panic('') }.as_map()
		assert m.invited_by(matrix_invite) == '@donp:donp.org'
	} else {
		assert false
	}
}

fn test_escape_char() {
	esc := '"\u001b[36mX"'
	assert esc.len == 8
	jstr := json2.raw_decode(esc) or { panic('') }.str()
	assert jstr.len == 6
}

fn test_mxn_split() {
	mxc_url := 'mxc://donp.org/DBKlXYNItaxXzLDEgJwNdKB'
	server, id := mxc_split(mxc_url)
	assert server == 'donp.org'
	assert id == 'DBKlXYNItaxXzLDEgJwNdKB'
}
