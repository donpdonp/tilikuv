module debug

pub fn debug<T>(a []&T) {
	println('DUMP arr: ${ptr_str(a)} ${typeof(a).name}')
	for b in a {
		println('DUMP: for b in a{} b => ${ptr_str(b)} ${typeof(b).name}')
	}
	for idx, _ in a {
		b := a[idx]
		println('DUMP: for idx, _ in a {} b := a[idx] => ${ptr_str(b)} ${typeof(b).name}')
	}
	for idx, _ in a {
		b := &a[idx]
		println('DUMP: for idx, _ in a {} b := &a[idx] => ${ptr_str(b)} ${typeof(b).name}')
	}
}
