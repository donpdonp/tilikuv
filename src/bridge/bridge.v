module bridge

import db

pub struct Bridge {
	left  string
	right string
}

pub fn (self Bridge) to_db() []db.SqlValue {
	mut parts := []db.SqlValue{}
	parts << &db.SqlValue{
		name: 'left'
		value: db.SqlType(self.left)
	}
	parts << &db.SqlValue{
		name: 'right'
		value: db.SqlType(self.right)
	}
	return parts
}

pub fn matching_room(lr string, mut db db.Db) ?string {
	lefts := db.select_by_field('bridge_rooms', 'left', lr)
	rights := db.select_by_field('bridge_rooms', 'right', lr)
	if lefts.len > 0 {
		println('bridge.matching room found left $lr -> right ${lefts[0][1]}')
		return lefts[0][1] // pick right
	} else if rights.len > 0 {
		println('bridge.matching room found right $lr -> left ${rights[0][0]}')
		return rights[0][0] // pick left
	}
	return error('no bridge found for $lr')
}

pub fn from_db(rows []string) &Bridge {
	return &Bridge{
		left: rows[0]
		right: rows[1]
	}
}
