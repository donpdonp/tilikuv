module irc

pub fn (mut self IrcActor) listen() {
	for {
		select {
			say := <-self.out {
				println('irc listen say<-self.out: $say')
			}
		}
	}
}
