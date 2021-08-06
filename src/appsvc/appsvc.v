module appsvc

import net
import io
import net.http
import setup
import x.json2
import strings

struct AppsvcActor {
pub:
	out       chan Command
	http_port string
}

struct Command {
pub:
	data map[string]json2.Any
}

pub fn setup(config setup.Config) &AppsvcActor {
	return &AppsvcActor{
		out: chan Command{}
		http_port: config.as_port
	}
}

pub fn (mut self AppsvcActor) listen() {
	mut l := net.listen_tcp(net.AddrFamily.ip, '$self.http_port') or {
		println('error opening appsvc port $self.http_port')
		return
	}
	println('appsvc listening $self.http_port')
	for {
		mut conn := l.accept() or { panic('accept() failed: $err') }
		peer_ip := conn.peer_ip() or { err.msg }
		mut reader := io.new_buffered_reader(reader: conn)
		header_lines := read_headerlines(mut reader)
		if header_lines.len > 0 {
			response := http.parse_response(header_lines.join('\n')) or { break }
			println('<- $peer_ip ${header_lines[0]}')
			if response.header.contains_custom('Content-Length') {
				self.process_request(response.header, mut reader)
			}
		}
		respond(mut conn, 200, '{}')
		conn.close() or { println('appsvc socket close err $err') }
	}
}

pub fn (mut self AppsvcActor) process_request(headers http.Header, mut reader io.BufferedReader) {
	len_str := headers.get_custom('Content-Length') or { return }
	http_body_len := len_str.int()
	mut body_bytes := []byte{len: int(http_body_len)}
	read_count := reader.read(mut body_bytes) or { 0 }
	if read_count > 0 {
		body := body_bytes.bytestr()
		if payload := json2.raw_decode(body) {
			events := payload.as_map()['events'].arr()
			for evt in events {
				self.out <- Command{
					data: evt.as_map()
				}
			}
		} else {
			println('appsvc body decode error $err')
		}
	} else {
		println('appsvc http body empty. content-length $http_body_len but read $read_count bytes')
	}
}

fn read_headerlines(mut reader io.BufferedReader) []string {
	mut lines := []string{}
	for {
		mut line := reader.read_line() or {
			println('read_headerlines read_line() BAIL')
			return lines
		}
		l := line.trim('\r\n')
		if l == '' {
			break
		}
		lines << l
	}
	return lines
}

pub fn respond(mut conn net.TcpConn, status_code int, body string) {
	mut sb := strings.new_builder(1024)
	status := http.status_from_int(status_code)
	sb.write_string('HTTP/1.1 $status_code $status\r\n')
	sb.write_string('Content-Type: application/json\r\n')
	sb.write_string('Content-Length: $body.len\r\n')
	sb.write_string('Connection: close\r\n')
	sb.write_string('\r\n')
	headers := sb.str()
	conn.write(headers.bytes()) or {}
	conn.write(body.bytes()) or {}
}
