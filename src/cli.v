module main

import setup
import net
import rpc
import json
import os

fn mmain() {
	mut words := os.args[1..] // copy the system args
	verb := if words.len == 0 { 'status' } else { words[0] }
	config := setup.config()
	host := '127.0.0.1:$config.rpc_port'
	println(host)
	mut conn := connect(host) or {
		println('cant connect to $host $err')
		return
	}
	params := parse(words[1..])
	cmd := build_cmd(verb, params)
	do(cmd, mut conn)
	println(conn.read_line())
}

fn parse(words []string) map[string]string {
	mut params := map[string]string{}
	for word in words {
		parts := word.split(':')
		if parts.len > 1 {
			params[parts[0]] = parts[1]
		}
	}
	params['line'] = words.join(' ')
	return params
}

fn connect(host string) ?&net.TcpConn {
	conn := net.dial_tcp(host)?
	conn.peer_addr()? // dial_tcp always works so use this
	return conn
}

fn do(cmd rpc.Command, mut conn net.TcpConn) string {
	mut jstr := json.encode(cmd)
	jstr += '\n'
	println(jstr)
	conn.write(jstr.bytes()) or {}
	conn.wait_for_read() or {}
	line := conn.read_line()
	println('status data: $line')
	return line
}

fn irc_add(ihost string, mut conn net.TcpConn) {
	mut params := map[string]string{}
	params['host'] = ihost
	cmd := build_cmd('connect', params)
	jstr := json.encode(cmd)
	println(jstr)
	conn.write(jstr.bytes()) or {}
}

fn build_cmd(verb string, params map[string]string) rpc.Command {
	cmd := rpc.Command{
		verb: verb
		params: params
	}
	return cmd
}
