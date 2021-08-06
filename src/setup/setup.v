module setup

import os
import json

pub struct Config {
pub:
	matrix_host  string = 'homeserver.example'
	matrix_owner string
	matrix_regex string
	irc_regex    string
	as_token     string = 'fixme'
	as_port      string = '127.0.0.1:9010'
	rpc_port     string = '127.0.0.1:9011'
	admin_room   string
}

pub fn config() Config {
	if json_str := os.read_file('config.json') {
		cfg := json.decode(Config, json_str) or {
			println('config.json is invalid json')
			exit(1)
		}
		if cfg.matrix_host.len == 0 {
			println('config.json: matrix_host setting is empty')
			exit(1)
		}
		return cfg
	} else {
		json_str := json.encode(Config{})
		os.write_file('config.json', json_str) or {
			println('cannot write config.json: $err')
			exit(1)
		}
		println('config.json created. edit this file then run again')
		exit(1)
	}
}
