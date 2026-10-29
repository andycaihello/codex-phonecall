#include "hfp-control-machine.hpp"
#include <cassert>
#include <iostream>
using phonebridge::HFP;
static void feed(HFP &h, const std::string &s, double t) { h.feed(s.data(), s.size(), t); }
static void snapshot(HFP &h, const std::string &values, double t) { feed(h, "+CIND: " + values + "\r\nOK\r\n", t); }
static void connect(HFP &h, const std::string &values = "0,1,0") {
    assert(h.configureIncomingBeforeStart()); h.start("connect");
    assert(h.takeWire(0) == "AT+BRSF=0\r"); feed(h, "+BRSF: 0\r\nOK\r\n", .01);
    assert(h.takeWire(.04) == "AT+CIND=?\r");
    feed(h, "+CIND: (\"call\",(0,1)),(\"callsetup\",(0-3)),(\"callheld\",(0-2))\r\nOK\r\n", .05);
    assert(h.takeWire(.08) == "AT+CIND?\r"); snapshot(h, values, .09);
    assert(h.takeWire(.12) == "AT+CMER=3,0,0,1\r"); feed(h, "OK\r\n", .13); assert(h.ready);
}
static uint64_t requestAnswer(HFP &h) {
    auto token = h.incomingToken; assert(token && h.incomingAvailable());
    assert(h.enqueue("answer", "answer1", "", token));
    assert(!h.enqueue("answer", "duplicate", "", token));
    assert(h.takeWire(1) == "AT+CIND?\r"); snapshot(h, "0,1,0", 1.01);
    assert(h.takeWire(1.04) == "ATA\r"); assert(h.firstWriteAllowed(1.05)); return token;
}
int main() {
    unsigned checks = 0;
    { HFP h; connect(h); assert(!h.enqueue("dial", "wrong", "5551234"));
      assert(!h.enqueue("answer", "stale", "", h.incomingToken + 1)); assert(h.takeWire(.5).empty()); checks += 3; }
    for (const std::string values : {"0,0,0", "1,0,0", "1,1,0", "0,1,1"}) {
        HFP h; connect(h, values); assert(!h.incomingAvailable());
        assert(!h.enqueue("answer", "wrong-state", "", 1)); checks += 2;
    }
    { HFP h; connect(h); auto token = requestAnswer(h); assert(h.ownIncoming && !h.ownDial);
      feed(h, "OK\r\n+CIEV: 1,1\r\n+CIEV: 2,0\r\n", 1.06);
      assert(h.ownsCall() && !h.incomingAvailable());
      assert(h.enqueue("hangup", "end")); assert(h.takeWire(1.1) == "AT+CIND?\r"); snapshot(h, "1,0,0", 1.11);
      assert(h.takeWire(1.14) == "AT+CHUP\r"); feed(h, "OK\r\n", 1.15);
      assert(h.takeWire(1.4) == "AT+CIND?\r"); snapshot(h, "0,0,0", 1.41);
      assert(h.idleVerified && !h.ownsCall());
      feed(h, "+CIEV: 2,1\r\nRING\r\n", 2); assert(h.incomingToken > token);
      assert(!h.enqueue("answer", "old", "", token));
      assert(h.enqueue("hangup", "unowned")); assert(h.takeWire(2.1) == "AT+CIND?\r"); snapshot(h, "0,1,0", 2.11);
      assert(h.takeWire(2.14).empty()); checks += 8; }
    // The caller disappears and another rings while the ATA is queued.
    { HFP h; connect(h); auto old = h.incomingToken;
      assert(h.enqueue("answer", "old", "", old)); assert(h.takeWire(1) == "AT+CIND?\r");
      feed(h, "+CIEV: 2,0\r\n+CIEV: 2,1\r\n", 1.005); snapshot(h, "0,1,0", 1.01);
      assert(h.incomingToken > old && h.takeWire(1.04).empty() && !h.ownsCall()); checks += 2; }
    // Drain-before-first-write catches the same race after ATA was staged.
    { HFP h; connect(h); requestAnswer(h);
      feed(h, "+CIEV: 2,0\r\n+CIEV: 2,1\r\n", 1.06);
      assert(!h.firstWriteAllowed(1.07)); h.cancelUnwrittenControl();
      assert(!h.ownsCall() && !h.hasOwnedDialIntent()); checks += 2; }
    { HFP h; connect(h); requestAnswer(h); feed(h, "ERROR\r\n", 1.06);
      assert(!h.ownsCall()); assert(!h.enqueue("hangup", "must-not-reject")); checks += 2; }
    // End/cancel before answer must not reject the incoming telephone.
    { HFP h; connect(h); auto token = h.incomingToken;
      assert(h.enqueue("answer", "a", "", token)); assert(h.enqueue("hangup", "cancel"));
      assert(h.takeWire(1) == "AT+CIND?\r"); snapshot(h, "0,1,0", 1.01);
      assert(h.takeWire(1.04).empty() && !h.ownsCall()); checks += 2; }
    { HFP h; connect(h); h.beginStop(); assert(!h.enqueue("answer", "stopped", "", h.incomingToken)); checks++; }
    { HFP h("5551234"); assert(!h.enqueue("answer", "outgoing", "", 1)); checks++; }
    // Repeated status snapshots retain the same ring token; reconnects do not reuse it.
    { HFP h; connect(h); auto token = h.incomingToken;
      for (int i=1;i<=50;++i) { assert(h.enqueue("refresh", "r")); assert(h.takeWire(i) == "AT+CIND?\r"); snapshot(h,"0,1,0",i+.01); assert(h.incomingToken == token); }
      h.disconnected(); connect(h); assert(h.incomingToken > token); checks += 51; }
    std::cout << "PASS: " << checks << " incoming state checks; no phone/audio/API operations\n";
}
