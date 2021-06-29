module rpc

import net
import io
import json
import setup
import matrix

struct Actor {
pub:
	out      chan Command
	rpc_port int
mut:
	clients []net.TcpConn
}

pub struct Command {
pub:
	verb   string
	params map[string]string
mut:
	client_connection_id int
}

pub fn init(config setup.Config) &Actor {
	mut self := &Actor{
		out: chan Command{}
		rpc_port: config.rpc_port
	}
	return self
}

pub fn (mut self Actor) listen() {
	mut l := net.listen_tcp(self.rpc_port) or {
		println('error opening rpc port')
		return
	}
	println('rpc listening $self.rpc_port')
	for {
		if conn := l.accept() {
			mut reader := io.new_buffered_reader(reader: conn)
			for {
				if line := reader.read_line() {
					mut cmd := json.decode(Command, line) or { panic(err) }
					cmd.client_connection_id = self.clients.len
					self.clients << conn
					self.out <- cmd
					// conn.close()
				} else {
					break
				}
			}
		} else {
			println('error accept() tcp')
		}
	}
}

struct StatusReport {
	host       string
	conn_state matrix.ConnState
}

pub fn (mut self Actor) status(cmd Command, config setup.Config, matrix &matrix.Actor) {
	println('rpc_status client #$cmd.client_connection_id')
	mut conn := self.clients[cmd.client_connection_id]
	addr := conn.peer_addr() or { panic(err) }
	println(addr)
	status_report := StatusReport{
		host: config.matrix_host
		conn_state: matrix.conn_state
	}
	mut jstr := json.encode(status_report)
	jstr += '\n'
	println('writing $jstr')
	conn.write_string(jstr) or { panic(err) }
}
