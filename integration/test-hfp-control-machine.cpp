#include "hfp-control-machine.hpp"
#include <cassert>
#include <iostream>
using phonebridge::HFP;
static constexpr const char *testNumber = "55512345678";
static const std::string defs = "+CIND: (\"service\",(0,1)),(\"call\",(0,1)),(\"callsetup\",(0-3)),(\"callheld\",(0-2)),(\"signal\",(0-5))\r\nOK\r\n";
static const std::string idle = "+CIND: 1,0,0,0,4\r\nOK\r\n";
static void feed(HFP &h, const std::string &s, double t) { h.feed(s.data(), s.size(), t); }
static void handshake(HFP &h) {
    h.start("connect1"); assert(h.takeWire(0) == "AT+BRSF=0\r"); feed(h, "+BRSF: 1023\r\nOK\r\n", .01);
    assert(h.takeWire(.04) == "AT+CIND=?\r"); feed(h, defs, .05);
    assert(h.takeWire(.08) == "AT+CIND?\r"); feed(h, idle, .09);
    assert(h.takeWire(.12) == "AT+CMER=3,0,0,1\r"); feed(h, "OK\r\n", .13);
    assert(h.ready && h.idle() && !h.ownDial); assert(h.takeWire(.17).empty());
}
static void refreshSoak(bool bytewise) {
    HFP h(testNumber); handshake(h); h.events.clear();
    for (unsigned i = 1; i <= 1000; ++i) {
        const double t = 1.0 + i;
        const std::string id = "soak-" + std::to_string(i);
        assert(h.enqueue("refresh", id));
        assert(h.takeWire(t) == "AT+CIND?\r");
        assert(h.pendingKind() == "refresh" && h.queued() == 0 && h.firstWriteAllowed(t));
        // This includes refresh 16 (total AT command 20) and all later transactions.
        if (bytewise) {
            for (size_t j = 0; j < idle.size(); ++j) h.feed(idle.data() + j, 1, t + .01);
        } else feed(h, idle, t + .01);
        assert(h.ready && !h.failed && h.idleVerified && h.idle());
        assert(!h.hasPending() && h.pendingKind().empty() && h.queued() == 0 && h.bufferedBytes() == 0);
        assert(!h.ownDial && !h.hasOwnedDialIntent() && !h.canRequestHSPAudio());
        assert(h.takeWire(t + .04).empty());
        h.checkTimeout(t + .5);
        assert(!h.failed);
        unsigned commands = 0, results = 0, snapshots = 0;
        for (const auto &event : h.events) {
            assert(event.ok);
            if (event.kind == "at_command") {
                assert(event.id == id && event.detail == "AT+CIND?"); ++commands;
            } else if (event.kind == "result") {
                assert(event.id == id && event.detail == "status_refreshed"); ++results;
            } else {
                assert(event.kind == "call_state" && event.detail == "CIND_snapshot"); ++snapshots;
            }
        }
        assert(commands == 1 && results == 1 && snapshots == 1);
        h.events.clear(); // Match the controller's per-tick event drain.
    }
}
int main() {
    unsigned cases = 0;
    { HFP unconfigured; handshake(unconfigured);
      assert(!unconfigured.enqueue("dial", "no-default", testNumber));
      assert(unconfigured.takeWire(1).empty() && !unconfigured.ownDial); ++cases; }
    { HFP configured; assert(configured.setPermittedNumberBeforeStart(testNumber)); handshake(configured);
      assert(configured.enqueue("dial", "explicit", testNumber));
      assert(configured.takeWire(1) == "AT+CIND?\r"); feed(configured, idle, 1.01);
      assert(configured.takeWire(1.1) == std::string("ATD") + testNumber + ";\r"); ++cases; }
    // Per-session destination: all of these are synthetic state-machine checks.
    for (const std::string &n : {"10010", "+442079460000", "55512345678"}) {
        assert(phonebridge::validDialNumber(n));
        HFP h(n); handshake(h);
        assert(!h.setPermittedNumberBeforeStart("12345"));
        assert(!h.enqueue("dial", "wrong", "12345"));
        assert(h.enqueue("dial", "right", n)); h.takeWire(1); feed(h, idle, 1.01);
        assert(h.takeWire(1.1) == "ATD" + n + ";\r"); ++cases;
    }
    for (const std::string &n : {"", "+", "12", "10010;ATH", "10010\r", "10010\n", "123#", "*123", "1234567890123456", "１２３"}) {
        assert(!phonebridge::validDialNumber(n)); HFP h(testNumber);
        assert(!h.setPermittedNumberBeforeStart(n)); ++cases;
    }
    // Explicit HFP-first admission is independently testable without frameworks or devices.
    { phonebridge::HFPAnchorPrerequisites good;
      good.paired = good.helperOpen = good.statusOK = good.peerVerified = good.active = good.awaitingHandshake = true;
      good.statusAge = .5; assert(phonebridge::allowedHFPAnchor(good)); ++cases;
      for (auto member : {&phonebridge::HFPAnchorPrerequisites::paired, &phonebridge::HFPAnchorPrerequisites::helperOpen,
                         &phonebridge::HFPAnchorPrerequisites::statusOK, &phonebridge::HFPAnchorPrerequisites::peerVerified,
                         &phonebridge::HFPAnchorPrerequisites::active, &phonebridge::HFPAnchorPrerequisites::awaitingHandshake}) {
        auto bad=good; bad.*member=false; assert(!phonebridge::allowedHFPAnchor(bad)); ++cases;
      }
      for (auto member : {&phonebridge::HFPAnchorPrerequisites::slcComplete, &phonebridge::HFPAnchorPrerequisites::pendingConnect,
                          &phonebridge::HFPAnchorPrerequisites::anyOwnedPhoneControl}) {
        auto bad=good; bad.*member=true; assert(!phonebridge::allowedHFPAnchor(bad)); ++cases;
      }
      for (double age : {-1., 5.001, 100.}) { auto bad=good; bad.statusAge=age; assert(!phonebridge::allowedHFPAnchor(bad)); ++cases; }
      for (double age : {0., 5.}) { auto edge=good; edge.statusAge=age; assert(phonebridge::allowedHFPAnchor(edge)); ++cases; }
    }
    for (bool hs : {false,true}) for (bool hf : {false,true}) for (bool ready : {false,true}) {
      assert(phonebridge::allowedHelperExchange(hs,hf,ready) == ((hs&&!hf)||(!hs&&hf&&ready))); ++cases;
    }
    { HFP h(testNumber); handshake(h); ++cases; }
    // No Bluetooth APIs or transport: repeat the same SLC plus 1000 read-only refreshes.
    for (bool bytewise : {false, true}) { refreshSoak(bytewise); ++cases; }
    // Every split boundary of both structured response types, including CR/LF and OK.
    for (size_t split = 0; split <= defs.size(); ++split) {
        HFP h(testNumber); h.start("x"); h.takeWire(0); feed(h, "+BRSF: 0\r\nOK\r\n", .01); h.takeWire(.04);
        feed(h, defs.substr(0,split), .05); feed(h, defs.substr(split), .06);
        assert(!h.failed && h.takeWire(.09) == "AT+CIND?\r"); ++cases;
    }
    for (size_t split = 0; split <= idle.size(); ++split) {
        HFP h(testNumber); h.start("x"); h.takeWire(0); feed(h, "+BRSF: 0\r\nOK\r\n", .01); h.takeWire(.04); feed(h, defs, .05); h.takeWire(.08);
        feed(h, idle.substr(0,split), .09); feed(h, idle.substr(split), .10);
        assert(!h.failed && h.takeWire(.13) == "AT+CMER=3,0,0,1\r"); ++cases;
    }
    { HFP h(testNumber); h.start("x"); h.takeWire(0); feed(h,"OK\r\n",.01); assert(h.failed); ++cases; }
    { HFP h(testNumber); h.start("x"); h.takeWire(0); feed(h,"+BRSF: 0\r\nOK\r\nOK\r\n",.01); assert(h.takeWire(.04)=="AT+CIND=?\r"); feed(h,"OK\r\n",.05); assert(h.failed); ++cases; }
    { HFP h(testNumber); h.start("x"); h.takeWire(0); h.checkTimeout(4); feed(h,"+BRSF: 0\r\nOK\r\n",5); assert(h.failed && h.takeWire(6).empty()); ++cases; }
    { HFP h(testNumber); handshake(h); h.enqueue("dial","d",testNumber); assert(h.takeWire(1)=="AT+CIND?\r"); feed(h,"+CIND: 1,1,0,0,4\r\nOK\r\n",1.01); assert(h.takeWire(1.1).empty() && !h.ownDial); ++cases; }
    { HFP h(testNumber); handshake(h); h.enqueue("dial","d",testNumber); h.takeWire(1); feed(h,idle,1.01); feed(h,"+CIEV: 3,1\r\nRING\r\n",1.02); assert(h.takeWire(1.1).empty() && !h.ownDial); ++cases; }
    { HFP h(testNumber); handshake(h); h.enqueue("dial","d",testNumber); assert(h.takeWire(1)=="AT+CIND?\r"); feed(h,idle,1.01);
      assert(h.takeWire(1.1)==std::string("ATD")+testNumber+";\r"); assert(h.ownDial && !h.idleVerified);
      feed(h,"OK\r\n+CIEV: 3,2\r\n+CIEV: 2,1\r\n+CIEV: 3,0\r\n",1.11); assert(h.call==1 && h.setup==0 && !h.idleVerified);
      assert(h.canRequestHSPAudio());
      assert(h.enqueue("hangup","h")); assert(h.takeWire(1.2)=="AT+CIND?\r"); feed(h,"+CIND: 1,1,0,0,4\r\nOK\r\n",1.21);
      assert(h.takeWire(1.3)=="AT+CHUP\r" && h.firstWriteAllowed(1.31)); feed(h,"OK\r\n",1.32);
      assert(h.takeWire(1.6)=="AT+CIND?\r"); feed(h,"+CIND: 1,1,0,0,4\r\nOK\r\n",1.61); assert(h.ownDial);
      assert(h.takeWire(1.9)=="AT+CIND?\r"); feed(h,idle,1.91); assert(!h.ownDial && h.idleVerified); ++cases; }
    { HFP h(testNumber); handshake(h); assert(!h.canRequestHSPAudio());
      h.enqueue("dial","d",testNumber); h.takeWire(1); feed(h,idle,1.01); h.takeWire(1.1);
      feed(h,"OK\r\n+CIEV: 3,2\r\n",1.11); assert(!h.canRequestHSPAudio());
      feed(h,"+CIEV: 2,1\r\n+CIEV: 3,0\r\n",1.12); assert(h.canRequestHSPAudio());
      feed(h,"+CIEV: 4,1\r\n",1.13); assert(!h.canRequestHSPAudio()); ++cases; }
    { HFP h(testNumber); handshake(h); h.enqueue("dial","d",testNumber); h.beginStop(); assert(h.takeWire(1).empty() && !h.ownDial); ++cases; }
    { HFP h(testNumber); handshake(h); h.enqueue("dial","d",testNumber); h.takeWire(1); h.beginStop(); feed(h,idle,1.01); assert(h.takeWire(1.1).empty() && !h.ownDial); ++cases; }
    { HFP h(testNumber); handshake(h); h.enqueue("dial","d",testNumber); h.takeWire(1); feed(h,idle,1.01); h.takeWire(1.1); h.cancelUnwrittenDial(); h.beginStop(); assert(h.takeWire(1.2).empty() && !h.ownDial); ++cases; }
    { HFP h(testNumber); handshake(h); h.enqueue("dial","d",testNumber); h.takeWire(1); feed(h,idle,1.01); h.takeWire(1.1); feed(h,"OK\r\n+CIEV: 5,3\r\n",1.11); assert(h.ownDial && !h.idleVerified); ++cases; }
    { HFP h(testNumber); handshake(h); assert(!h.enqueue("hangup","h")); assert(h.takeWire(1).empty()); ++cases; }
    { HFP h(testNumber); handshake(h); for (int i=0;i<16;i++) assert(h.enqueue("refresh",std::to_string(i))); assert(!h.enqueue("refresh","overflow")); ++cases; }
    { HFP h(testNumber); handshake(h); feed(h,std::string(2049,'X'),1); assert(h.failed); ++cases; }
    { HFP h(testNumber); handshake(h); feed(h,std::string(1,'\0'),1); assert(h.failed); ++cases; }
    { HFP h(testNumber); handshake(h); feed(h,"+CIEV: 2,9\r\n",1); assert(h.failed); ++cases; }
    { HFP h(testNumber); handshake(h); h.enqueue("refresh","r"); h.takeWire(1); feed(h,"+CIND: 1,0,0\r\nOK\r\n",1.01); assert(h.failed); ++cases; }
    // Hangup cancels a queued dial before it even starts its idle preflight.
    { HFP h(testNumber); handshake(h); assert(h.enqueue("dial","d",testNumber)); assert(h.enqueue("hangup","h"));
      assert(h.takeWire(1)=="AT+CIND?\r"); feed(h,idle,1.01); assert(h.takeWire(1.1).empty() && !h.ownDial && h.idleVerified); ++cases; }
    // Already-sent CIND preflight must drain its own reply; cancellation gets a NEW snapshot.
    { HFP h(testNumber); handshake(h); h.enqueue("dial","d",testNumber); h.takeWire(1); assert(h.enqueue("hangup","h"));
      feed(h,idle,1.01); assert(!h.ownDial && h.takeWire(1.1)=="AT+CIND?\r"); feed(h,idle,1.11);
      assert(h.takeWire(1.2).empty() && h.idleVerified); ++cases; }
    // Dial already enqueued after preflight OK, but before takeWire.
    { HFP h(testNumber); handshake(h); h.enqueue("dial","d",testNumber); h.takeWire(1); feed(h,idle,1.01);
      assert(h.enqueue("hangup","h")); assert(h.takeWire(1.1)=="AT+CIND?\r"); feed(h,idle,1.11); assert(!h.ownDial && h.takeWire(1.2).empty()); ++cases; }
    // Transport has staged ATD but has written zero bytes; cancellation removes it.
    { HFP h(testNumber); handshake(h); h.enqueue("dial","d",testNumber); h.takeWire(1); feed(h,idle,1.01); h.takeWire(1.1);
      h.cancelUnwrittenDial(); assert(h.enqueue("hangup","h")); assert(h.takeWire(1.2)=="AT+CIND?\r"); feed(h,idle,1.21);
      assert(!h.ownDial && h.idleVerified && h.takeWire(1.3).empty()); ++cases; }
    // Incoming call after cancellation is never sent CHUP and cannot count as idle proof.
    { HFP h(testNumber); handshake(h); h.enqueue("dial","d",testNumber); h.enqueue("hangup","h"); h.takeWire(1);
      feed(h,"+CIND: 1,0,1,0,4\r\nOK\r\n",1.01); assert(h.takeWire(1.1).empty() && !h.ownDial && !h.idleVerified); ++cases; }
    // Our observed outgoing lifecycle ends; a later incoming call cannot inherit it.
    { HFP h(testNumber); handshake(h); h.enqueue("dial","d",testNumber); h.takeWire(1); feed(h,idle,1.01); h.takeWire(1.1);
      feed(h,"OK\r\n+CIEV: 3,2\r\n+CIEV: 2,1\r\n+CIEV: 3,0\r\n+CIEV: 2,0\r\n",1.11);
      assert(!h.ownDial && h.idleVerified); feed(h,"RING\r\n+CIEV: 3,1\r\n",1.12); assert(!h.ownDial && !h.idleVerified);
      assert(h.enqueue("hangup","h")); assert(h.takeWire(1.2)=="AT+CIND?\r"); feed(h,"+CIND: 1,0,1,0,4\r\nOK\r\n",1.21);
      assert(h.takeWire(1.3).empty() && !h.ownDial); ++cases; }
    // New incoming indication between fresh hangup data and OK must defeat CHUP.
    { HFP h(testNumber); handshake(h); h.enqueue("dial","d",testNumber); h.takeWire(1); feed(h,idle,1.01); h.takeWire(1.1);
      feed(h,"OK\r\n+CIEV: 3,2\r\n",1.11); h.enqueue("hangup","h"); assert(h.takeWire(1.2)=="AT+CIND?\r");
      feed(h,"+CIND: 1,0,2,0,4\r\nRING\r\nOK\r\n",1.21); assert(h.takeWire(1.3).empty()); ++cases; }
    // CHUP staged before transport write: incoming RING or lifecycle end cancels first send.
    for (const auto &incoming : {std::string("RING\r\n"), std::string("+CIEV: 3,0\r\n")}) {
      HFP h(testNumber); handshake(h); h.enqueue("dial","d",testNumber); h.takeWire(1); feed(h,idle,1.01); h.takeWire(1.1);
      feed(h,"OK\r\n+CIEV: 3,2\r\n",1.11); h.enqueue("hangup","h"); h.takeWire(1.2);
      feed(h,"+CIND: 1,0,2,0,4\r\nOK\r\n",1.21); assert(h.takeWire(1.3)=="AT+CHUP\r" && h.firstWriteAllowed(1.31));
      feed(h,incoming,1.32); assert(!h.firstWriteAllowed(1.33)); h.cancelUnwrittenControl(); assert(h.takeWire(1.4).empty()); ++cases;
    }
    // ATD staged: a fresh incoming indication before send prevents any dial bytes.
    { HFP h(testNumber); handshake(h); h.enqueue("dial","d",testNumber); h.takeWire(1); feed(h,idle,1.01); h.takeWire(1.1);
      assert(h.firstWriteAllowed(1.11)); feed(h,"RING\r\n",1.12); assert(!h.firstWriteAllowed(1.13)); h.cancelUnwrittenControl(); assert(!h.ownDial); ++cases; }
    // A post-ATD idle snapshot before any lifecycle change must not claim ended or send CHUP blindly.
    { HFP h(testNumber); handshake(h); h.enqueue("dial","d",testNumber); h.takeWire(1); feed(h,idle,1.01); h.takeWire(1.1); feed(h,"OK\r\n",1.11);
      h.enqueue("refresh","r"); h.takeWire(1.2); feed(h,idle,1.21); assert(h.ownDial && !h.idleVerified);
      h.enqueue("hangup","h"); assert(h.takeWire(1.3)=="AT+CIND?\r"); feed(h,idle,1.31); assert(h.ownDial && !h.idleVerified);
      assert(h.takeWire(1.6)=="AT+CIND?\r"); feed(h,"+CIND: 1,0,2,0,4\r\nOK\r\n",1.61); assert(h.takeWire(1.7)=="AT+CHUP\r"); ++cases; }
    // Aggregate active/held indicators cannot identify which call leg CHUP would affect.
    for (int heldValue : {1, 2}) {
      HFP h(testNumber); handshake(h); h.enqueue("dial","d",testNumber); h.takeWire(1); feed(h,idle,1.01); h.takeWire(1.1);
      feed(h,"OK\r\n+CIEV: 3,2\r\n+CIEV: 2,1\r\n+CIEV: 3,0\r\n",1.11);
      h.enqueue("hangup","h"); assert(h.takeWire(1.2)=="AT+CIND?\r");
      feed(h,"+CIND: 1,1,0,"+std::to_string(heldValue)+",4\r\nOK\r\n",1.21);
      assert(h.takeWire(1.3).empty()); assert(h.takeWire(1.6)=="AT+CIND?\r"); ++cases;
    }
    for (const auto &s : {std::string("7002"), std::string("+86")+testNumber, std::string(testNumber)+";", std::string(testNumber)+"\rAT+CHUP", std::string("10010")}) { HFP h(testNumber); handshake(h); assert(!h.enqueue("dial", "wrong-target", s)); assert(h.takeWire(1).empty()); ++cases; }
    std::cout << "{\"passed\":true,\"cases\":" << cases << ",\"refreshSoakSessions\":2,\"refreshSoakTransactions\":2000,\"deviceQueries\":false,\"wireTransportUsed\":false}\n";
}
