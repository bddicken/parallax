use tokio::sync::broadcast;

use crate::protocol::{Account, BroadcastStatus, ChatMessage, ServerEvent};

/// Fans server events out to every `/v1/events` subscriber.
#[derive(Clone)]
pub struct Events(broadcast::Sender<ServerEvent>);

impl Events {
    pub fn new() -> Events {
        Events(broadcast::channel(256).0)
    }

    pub fn subscribe(&self) -> broadcast::Receiver<ServerEvent> {
        self.0.subscribe()
    }

    // Sending fails only when nobody is listening, which is fine.
    pub fn chat(&self, message: ChatMessage) {
        let _ = self.0.send(ServerEvent::Chat(message));
    }

    pub fn status(&self, status: BroadcastStatus) {
        let _ = self.0.send(ServerEvent::Status(status));
    }

    pub fn accounts(&self, accounts: Vec<Account>) {
        let _ = self.0.send(ServerEvent::Accounts(accounts));
    }
}
