module util

type StringOrNone = None | string

pub struct None {}

pub fn (self None) str() string {
	return '-none-'
}

pub fn ctcp_decode(msg string) ?string {
	// vlang regex doesnt support \x00 : r'^\x01.*$'
	if msg[0] == 1 {
		return msg[1..msg.len - 1]
	} else {
		return error('not a CTCP command')
	}
}

pub fn ctcp_encode(verb string, msg string) string {
	soh := byte(1).ascii_str()
	return soh + verb + ' ' + msg + soh
}
