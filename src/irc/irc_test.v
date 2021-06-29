module irc

fn test_parse_ping() {
	irc_msg := 'PING ircbob'
	parts := parse(irc_msg)
	assert parts.len == 2
}

fn test_parse_251() {
	irc_msg := ':oragono.test 251 ircvbridge :There are 0 users and 1 invisible on 1 server(s)'
	parts := parse(irc_msg)
	assert parts.len == 6
}

fn test_is_room() {
	ircm := setup()
	assert ircm.is_room('#room')
	assert ircm.is_room('#roomy-room')
	assert ircm.is_room('#roomy-room:donp.org') == false
	assert ircm.is_room('!FMIqCsoGJDbtjiBptb:donp.org') == false
}

fn test_dial() {
	mut ircm := setup()
	mut ircnet := Network{
		hostname: 'google.com:443'
	}
	ircm.dial(mut ircnet, 'nick')
	assert true
}

fn test_capabilities_decode() {
	//:molybdenum.libera.chat 005 abcdef WHOX KNOCK MONITOR=100 ETRACE FNC SAFELIST ELIST=CTU CALLERID=g CHANTYPES=# EXCEPTS INVEX CHANMODES=eIbq,k,flj,CFLMPQScgimnprstuz :are supported by this server
	//:molybdenum.libera.chat 005 abcdef CHANLIMIT=#:250 PREFIX=(ov)@+ MAXLIST=bqeI:100 MODES=4 NETWORK=Libera.Chat STATUSMSG=@+ CASEMAPPING=rfc1459 NICKLEN=16 MAXNICKLEN=16 CHANNELLEN=50 TOPICLEN=390 DEAF=D :are supported by this server
	cap := capabilities_decode('KEY=VALUE')
	assert cap['KEY'] == 'VALUE'
}
