module util

struct Thing {
	name StringOrNone
}

fn test_string_or_none_string() {
	thing := Thing{
		name: StringOrNone('bob')
	}
	println(thing)
	assert thing.name is string
}

fn test_string_or_none_none() {
	thing := Thing{
		name: StringOrNone(None{})
	}
	println(thing)
	assert thing.name is None
}

fn test_is_ctcp() {
	verb := 'ACTION'
	msg := 'hop'
	ctcp_msg := '\1' + '$verb $msg' + '\1'

	assert ctcp_encode(verb, msg) == ctcp_msg

	if code := ctcp_decode(ctcp_msg) {
		assert code == '$verb $msg'
	} else {
		assert false
	}
}
