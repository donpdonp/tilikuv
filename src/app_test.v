module main

fn test_regex_name_match() {
	rex := '(.*)|mv'
	if name := regex_name_match('(.*)|mv', 'donp|mv') {
		assert name == 'donp'
	} else {
		assert false
	}
	if _ := regex_name_match('(.*)|mv', 'donpdonp') {
		assert false
	} else {
		assert true
	}
}

fn test_regex_self_replace() {
	assert regex_self_replace('(.*)|mv', 'donp') == 'donp|mv'
}
