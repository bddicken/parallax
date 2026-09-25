use std::sync::Arc;

use tokio::sync::{Notify, broadcast};

use crate::protocol::{Account, BroadcastStatus, ChatMessage, ServerEvent};

/// Fans server events out to every `/v1/events` subscriber.
#[derive(Clone)]
pub struct Events(broadcast::Sender<ServerEvent>, Arc<Notify>);

impl Events {
    pub fn new() -> Events {
        Events(broadcast::channel(256).0, Arc::default())
    }

    pub fn subscribe(&self) -> broadcast::Receiver<ServerEvent> {
        self.0.subscribe()
    }

    /// A platform's sign-in changed. The API rebuilds the full account list
    /// (see `api::publish_accounts`), since each platform only knows its own.
    pub fn accounts_changed(&self) {
        self.1.notify_one();
    }

    pub async fn wait_for_account_change(&self) {
        self.1.notified().await;
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
