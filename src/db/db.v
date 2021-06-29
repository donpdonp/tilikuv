module db

import sqlite
import setup
import log

struct Db {
	sqlite sqlite.DB
mut:
	log log.Log
}

type SqlType = int | string

pub struct SqlValue {
	name  string
	value SqlType
}

pub fn init(config setup.Config) Db {
	dbo := sqlite.connect('db.sqlite') or {
		println('cannot open db.sqlite $err')
		exit(1)
	}
	mut db := Db{
		sqlite: dbo
	}
	db.log.set_full_logpath('log/sql')
	db.log.set_level(.debug)
	db.create_table('irc_servers', ['netname text', 'hostname text primary key', 'nick text'])
	db.create_table('irc_channels', ['channel text primary key', 'netname text'])
	db.create_table('matrix_rooms', ['room_id text primary key', 'name text'])
	db.create_table('bridge_rooms', ['left text primary key', 'right text'])
	db.create_table('bridge_nicks', ['matrix text primary key', 'irc text'])
	return db
}

pub fn (mut self Db) create_table(table string, fields []string) {
	self.exec_oneshot('create table if not exists $table (${fields.join(',')})')
}

pub fn (mut self Db) exec_oneshot(stmt string) {
	self.log.debug('sqlite: $stmt')
	self.sqlite.exec_one(stmt) or {}
}

pub fn (mut self Db) exec(stmt string) [][]string {
	rows, code := self.sqlite.exec(stmt)
	self.log.debug('sqlite: $stmt = $rows.len rows $code')
	println('sqlite: $stmt; [$rows.len rows. status $code]')
	strs := rows.map(it.vals)
	return strs
}

pub fn (mut self Db) insert(table string, parts []SqlValue) {
	mut fields := []string{}
	mut values := []string{}
	for part in parts {
		fields << part.name
		match part.value {
			int {
				values << part.value.str()
			}
			string {
				values << '"$part.value"'
			}
		}
	}
	stmt := 'insert into $table (${fields.join(',')}) values (${values.join(',')})'
	rows, code := self.sqlite.exec(stmt)
	self.log.debug('SQL $stmt $rows $code')
	println('sqlite: $stmt; [$rows.len rows. status $code]')
}

pub fn (mut self Db) update_by_field(table string, id_field string, id_value string, field string, value string) [][]string {
	zql := 'update $table set $field = "$value" where $id_field = "$id_value"'
	rows := self.exec(zql)
	self.log.debug('SQL $zql $rows')
	return rows
}

pub fn (mut self Db) delete_by_field(table string, field string, value string) {
	self.action_by_field('delete', table, field, value)
}

pub fn (mut self Db) select_by_field(table string, field string, value string) [][]string {
	return self.action_by_field('select *', table, field, value)
}

pub fn (mut self Db) action_by_field(action string, table string, field string, value string) [][]string {
	zql := '$action from $table where $field = "$value"'
	rows := self.exec(zql)
	self.log.debug('SQL $zql $rows')
	return rows
}

pub fn (mut self Db) select_all(table string) [][]string {
	stmt := 'select * from $table'
	return self.exec(stmt)
}
