class MeetingStateEventHandler extends SDEventHandler {
  constructor(connectionManager) {
    super(connectionManager);
    this._lastActive = null;
    this._observer = null;
  }

  initialize = () => {
    this._registerMutationObserver();
    this._sendMeetingState();
  }

  onNewStreamDeckConnection = () => {
    this._sendMeetingState();
  }

  _isMeetingActive = () => {
    return Boolean(document.querySelector('[jsname="CQylAd"]'));
  }

  _sendMeetingState = () => {
    const active = this._isMeetingActive();
    if (active === this._lastActive) return;
    this._lastActive = active;
    this._connectionManager.sendMessage({
      event: "meetingState",
      active: active
    });
  }

  _registerMutationObserver = () => {
    if (this._observer) return;
    this._observer = new MutationObserver(() => this._sendMeetingState());
    this._observer.observe(document.body, {
      childList: true,
      subtree: true,
    });
  }
}
