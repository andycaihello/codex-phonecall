#pragma once
// Pure bounded HFP AT transaction/state machine. No Bluetooth or audio APIs.
#include <algorithm>
#include <deque>
#include <map>
#include <regex>
#include <set>
#include <sstream>
#include <string>
#include <vector>

namespace phonebridge {
inline bool validDialNumber(const std::string &n) {
    size_t first = !n.empty() && n[0] == '+' ? 1 : 0;
    size_t count = n.size() - first;
    return count >= 3 && count <= 15 && std::all_of(n.begin() + first, n.end(), [](char c) { return c >= '0' && c <= '9'; });
}
// Pure admission policy for the explicit HFP-first experiment.
struct HFPAnchorPrerequisites {
    bool paired = false, helperOpen = false, statusOK = false, peerVerified = false;
    bool active = false, slcComplete = false, awaitingHandshake = false;
    bool pendingConnect = false, anyOwnedPhoneControl = false;
    double statusAge = -1;
};
inline bool allowedHFPAnchor(const HFPAnchorPrerequisites &p) {
    return p.paired && p.helperOpen && p.statusOK && p.peerVerified && p.active &&
        !p.slcComplete && p.awaitingHandshake && !p.pendingConnect && !p.anyOwnedPhoneControl &&
        p.statusAge >= 0 && p.statusAge <= 5;
}
inline bool allowedHelperExchange(bool hspLive, bool hfpLive, bool selectedHFPAnchorReady) {
    return (hspLive && !hfpLive) || (!hspLive && hfpLive && selectedHFPAnchorReady);
}
struct Event { std::string kind, id, detail; bool ok = false; };
struct Job { std::string kind, id; double verifyUntil = 0; };
class HFP {
public:
    explicit HFP(std::string number = "") : permittedNumber(validDialNumber(number) ? std::move(number) : "") {}
    bool setPermittedNumberBeforeStart(const std::string &number) {
        if (stage != "disconnected" || ready || ownDial || !queue.empty() || !validDialNumber(number)) return false;
        permittedNumber = number; return true;
    }
    bool ready = false, failed = false, ownDial = false, idleVerified = false, stopping = false;
    int call = -1, setup = -1, held = -1;
    std::string stage = "disconnected";
    std::vector<Event> events;
    void start(const std::string &id) {
        reset(); connectID = id; stage = "slc"; queue.push_back({"brsf", id});
    }
    void reset() {
        ready = failed = ownDial = idleVerified = stopping = false; call = setup = held = -1;
        stage = "disconnected"; queue.clear(); pending = {}; rx.clear(); names.clear(); values.clear();
        deadline = 0; lastSnapshot = -100; nextAt = 0; responseSeen = false; dialQueued = false; ring = false;
        callActivityObserved = preflightCancelled = cancelledIntentNeedsSnapshot = endedOwnedCall = ownershipContested = false; connectID.clear();
    }
    void disconnected() {
        if (!pending.kind.empty()) events.push_back({"result", pending.id, "control_disconnected", false});
        for (const auto &j : queue) if (!j.id.empty()) events.push_back({"result", j.id, "control_disconnected", false});
        queue.clear(); pending = {}; ready = false; stage = "disconnected";
        // Keep ownership/unknown call state visible; RFCOMM close does not hang up.
        idleVerified = false; events.push_back({"state", "", "control_disconnected; call_end_not_verified", false});
    }
    bool enqueue(const std::string &op, const std::string &id, const std::string &number = "") {
        if (stopping && op != "hangup" && op != "refresh") { events.push_back({"result", id, "shutdown_in_progress", false}); return false; }
        if (!ready || failed) { events.push_back({"result", id, "hfp_slc_not_ready", false}); return false; }
        if (op != "hangup" && queue.size() >= 16) { events.push_back({"result", id, "queue_full", false}); return false; }
        if (op == "dial") {
            if (!validDialNumber(number) || number != permittedNumber) { events.push_back({"result", id, "number_not_allowlisted", false}); return false; }
            if (ownDial || dialQueued || cancelledIntentNeedsSnapshot || preflightCancelled) { events.push_back({"result", id, "owned_dial_already_pending", false}); return false; }
            dialQueued = true; endedOwnedCall = cancelledIntentNeedsSnapshot = false; queue.push_back({"dial_preflight", id});
        } else if (op == "refresh") queue.push_back({"refresh", id});
        else if (op == "hangup") {
            // Cancellation is an operation on our queued intent, even before ATD sets ownDial.
            bool cancelled = cancelledIntentNeedsSnapshot || dialQueued || pending.kind == "dial_preflight";
            if (!ownDial && !cancelled && !endedOwnedCall) { events.push_back({"result", id, "no_owned_dial; no_hangup_sent", false}); return false; }
            for (const auto &j : queue) if (!j.id.empty()) events.push_back({"result", j.id, "cancelled_for_owned_hangup_before_write", false});
            queue.clear(); dialQueued = false;
            if (pending.kind == "dial_preflight") preflightCancelled = true; // Drain its reply; never reuse an OK.
            if (cancelled && !ownDial) {
                cancelledIntentNeedsSnapshot = true; queue.push_front({"cancel_verify", id});
            } else queue.push_front({"hangup_preflight", id});
        } else { events.push_back({"result", id, "unknown_hfp_operation", false}); return false; }
        return true;
    }
    std::string takeWire(double now) {
        checkTimeout(now);
        if (failed || !pending.kind.empty() || queue.empty() || !rx.empty() || now < nextAt) return "";
        pending = queue.front(); queue.pop_front(); responseSeen = false;
        if (pending.kind == "dial" && (!idle() || ring || stopping || now - lastSnapshot > 2)) {
            events.push_back({"result", pending.id, "call_changed_before_dial", false});
            pending = {}; dialQueued = false; return "";
        }
        if (pending.kind == "hangup" && !hangupWriteAllowed(now)) {
            events.push_back({"result", pending.id, "call_ownership_changed_before_CHUP; no_hangup_sent", false});
            pending = {}; return "";
        }
        if (pending.kind == "hangup_preflight" && !pending.verifyUntil) pending.verifyUntil = now + 5;
        stage = pending.kind; deadline = now + 4;
        std::string wire;
        if (pending.kind == "brsf") wire = "AT+BRSF=0\r";
        else if (pending.kind == "cind_defs") wire = "AT+CIND=?\r";
        else if (pending.kind == "cmer") { wire = "AT+CMER=3,0,0,1\r"; responseSeen = true; }
        else if (pending.kind == "dial") {
            wire = std::string("ATD") + permittedNumber + ";\r"; ownDial = true; idleVerified = false; callActivityObserved = false; endedOwnedCall = ownershipContested = false;
            responseSeen = true; dialQueued = false;
        } else if (pending.kind == "hangup") { wire = "AT+CHUP\r"; responseSeen = true; }
        else wire = "AT+CIND?\r";
        events.push_back({"at_command", pending.id, pending.kind == "dial" ? "ATD***" + permittedNumber.substr(permittedNumber.size() > 4 ? permittedNumber.size() - 4 : 0) + ";" : wire.substr(0, wire.size() - 1), true});
        return wire;
    }
    void feed(const char *p, size_t n, double now) {
        if (n > 8192) { fail("receive_chunk_limit"); return; }
        for (size_t i = 0; i < n; ++i) {
            unsigned char c = static_cast<unsigned char>(p[i]);
            if (c == '\r' || c == '\n') {
                if (!rx.empty()) { std::string line = rx; rx.clear(); process(line, now); }
            } else if (c >= 32 && c < 127) {
                rx.push_back(char(c)); if (rx.size() > 2048) { fail("control_line_limit"); return; }
            } else { fail("non_ascii_control_data"); return; }
        }
    }
    void checkTimeout(double now) {
        if (!pending.kind.empty() && now >= deadline) fail("command_timeout; reply_stream_desynchronized");
    }
    void fail(const std::string &reason) {
        if (failed) return;
        failed = true; ready = false; stage = "failed"; idleVerified = false;
        events.push_back({"result", pending.id.empty() ? connectID : pending.id, reason, false});
        for (const auto &j : queue) if (!j.id.empty() && j.id != pending.id) events.push_back({"result", j.id, "cancelled_after_protocol_failure", false});
        queue.clear(); pending = {}; events.push_back({"protocol_failed", "", reason, false});
    }
    bool idle() const { return call == 0 && setup == 0 && held == 0; }
    bool hasOwnedDialIntent() const { return ownDial || dialQueued || preflightCancelled || cancelledIntentNeedsSnapshot; }
    bool hasPending() const { return !pending.kind.empty() || !queue.empty(); }
    std::string pendingKind() const { return pending.kind; }
    size_t bufferedBytes() const { return rx.size(); }
    bool pendingResponseSeen() const { return responseSeen; }
    // HSP's headset-button command is context-sensitive. Permit it only after
    // this controller's outgoing call has reached one active, unheld call and
    // while no HFP transaction can change that ownership/state underneath it.
    bool canRequestHSPAudio() const {
        return ready && !failed && ownDial && callActivityObserved && !ownershipContested && !ring &&
            call == 1 && setup == 0 && held == 0 && !hasPending();
    }
    void cancelUnwrittenDial() {
        if (pending.kind != "dial") return;
        events.push_back({"result", pending.id, "cancelled_before_ATD_write", false});
        pending = {}; ownDial = false; dialQueued = false; cancelledIntentNeedsSnapshot = true;
    }
    // Called immediately before the transport's first send, after draining unsolicited input.
    // Once any bytes were written, transport must finish that AT line instead of truncating it.
    bool firstWriteAllowed(double now) const {
        if (failed || pending.kind.empty() || now >= deadline) return false;
        if (pending.kind == "dial") return !stopping && idle() && !ring && !ownershipContested && now - lastSnapshot <= 2;
        if (pending.kind == "hangup") return hangupWriteAllowed(now);
        return true;
    }
    void cancelUnwrittenControl() {
        if (pending.kind == "dial") { cancelUnwrittenDial(); return; }
        if (!pending.kind.empty()) events.push_back({"result", pending.id, "call_ownership_changed_before_write; command_not_sent", false});
        pending = {};
    }
    void beginStop() {
        stopping = true;
        for (const auto &j : queue) if (!j.id.empty()) events.push_back({"result", j.id, "cancelled_for_shutdown_before_write", false});
        queue.clear(); dialQueued = false;
    }
    bool awaitingBytes() const { return !pending.kind.empty(); }
    size_t queued() const { return queue.size(); }
private:
    std::string permittedNumber;
    std::deque<Job> queue; Job pending;
    std::string rx, connectID;
    std::vector<std::string> names;
    std::map<std::string, int> values;
    double deadline = 0, lastSnapshot = -100, nextAt = 0;
    bool responseSeen = false, dialQueued = false, ring = false, callActivityObserved = false;
    bool preflightCancelled = false, cancelledIntentNeedsSnapshot = false, endedOwnedCall = false, ownershipContested = false;
    bool hangupWriteAllowed(double now) const {
        return ownDial && callActivityObserved && !ownershipContested && !ring && setup != 1 && held == 0 &&
            !idle() && now - lastSnapshot <= 2;
    }
    void observeCallState(bool fullSnapshot, bool callIndicator) {
        if (ownDial && (ring || setup == 1)) ownershipContested = true;
        if (ownDial && !ownershipContested && (setup == 2 || setup == 3 || call == 1)) callActivityObserved = true;
        // A battery/signal CIEV cannot finish a dial whose call lifecycle has not been observed.
        if (ownDial && callActivityObserved && idle() && (fullSnapshot || callIndicator)) {
            ownDial = false; endedOwnedCall = true; ownershipContested = false;
            events.push_back({"owned_call_ended", "", "observed_owned_lifecycle_returned_idle", true});
        }
        idleVerified = idle() && !ring && !ownDial;
    }
    static bool match(const std::string &line, const char *pattern) { return std::regex_match(line, std::regex(pattern)); }
    bool apply(const std::string &name, int value) {
        if ((name == "call" && value > 1) || (name == "callsetup" && value > 3) || (name == "callheld" && value > 2) || value < 0 || value > 255) return false;
        values[name] = value;
        if (name == "call") call = value;
        if (name == "callsetup") setup = value;
        if (name == "callheld") held = value;
        return true;
    }
    bool definitions(const std::string &line) {
        if (!match(line, R"(^\+CIND:\s*\("[a-z][a-z0-9]{0,23}",\s*\([0-9,\- ]+\)\)(\s*,\s*\("[a-z][a-z0-9]{0,23}",\s*\([0-9,\- ]+\)\))*$)")) return false;
        std::regex r("\"([^\"]+)\""); std::set<std::string> unique; std::vector<std::string> parsed;
        for (std::sregex_iterator it(line.begin(), line.end(), r), end; it != end; ++it) {
            std::string name = (*it)[1]; if (!unique.insert(name).second) return false; parsed.push_back(name);
        }
        if (parsed.size() > 32 || !unique.count("call") || !unique.count("callsetup") || !unique.count("callheld")) return false;
        names = parsed; return true;
    }
    bool snapshot(const std::string &line, double now) {
        if (!match(line, R"(^\+CIND:\s*[0-9]{1,3}(\s*,\s*[0-9]{1,3}){0,31}$)")) return false;
        std::string body = line.substr(line.find(':') + 1); std::replace(body.begin(), body.end(), ',', ' ');
        std::istringstream in(body); std::vector<int> parsed; int value;
        while (in >> value) parsed.push_back(value);
        if (parsed.size() != names.size()) return false;
        for (size_t i = 0; i < parsed.size(); ++i) if (!apply(names[i], parsed[i])) return false;
        lastSnapshot = now; ring = setup == 1; observeCallState(true, true);
        events.push_back({"call_state", "", "CIND_snapshot", true}); return true;
    }
    void process(const std::string &line, double now) {
        if (line == "RING") { ring = true; if (ownDial) ownershipContested = true; idleVerified = false; events.push_back({"ring", "", "incoming_call_indication", true}); return; }
        std::smatch m;
        if (std::regex_match(line, m, std::regex(R"(^\+CIEV:\s*([0-9]{1,2})\s*,\s*([0-9]{1,3})$)"))) {
            int index = std::stoi(m[1]), value = std::stoi(m[2]);
            if (index < 1 || size_t(index) > names.size() || !apply(names[index - 1], value)) { fail("invalid_CIEV"); return; }
            const std::string &name = names[index - 1];
            bool callIndicator = name == "call" || name == "callsetup" || name == "callheld";
            if (name == "callsetup" && setup != 1) ring = false;
            observeCallState(false, callIndicator);
            events.push_back({"call_state", "", "CIEV", true}); return;
        }
        if (failed) return; // Preserve CIEV evidence after a failure but never reuse late OKs.
        if (pending.kind.empty()) {
            if (line == "OK" || line == "ERROR") events.push_back({"orphan_result", "", line + "; not_applied_to_next_command", false});
            return;
        }
        if (line == "ERROR" || line.rfind("+CME ERROR:", 0) == 0 || line == "NO CARRIER" || line == "BUSY" || line == "NO ANSWER") {
            if (!ready) { fail("AG_rejected_SLC"); return; }
            events.push_back({"result", pending.id, "AG_rejected_command; call_state_requires_refresh", false});
            if (pending.kind == "dial_preflight") preflightCancelled = false;
            pending = {}; dialQueued = false; nextAt = now + .02; return;
        }
        if (pending.kind == "brsf" && match(line, R"(^\+BRSF:\s*[0-9]{1,10}$)")) responseSeen = true;
        else if (pending.kind == "cind_defs" && line.rfind("+CIND:", 0) == 0) {
            if (!definitions(line)) { fail("invalid_CIND_definitions"); return; } responseSeen = true;
        } else if (line.rfind("+CIND:", 0) == 0 && (pending.kind == "cind_initial" || pending.kind == "refresh" || pending.kind == "dial_preflight" || pending.kind == "hangup_preflight" || pending.kind == "cancel_verify" || pending.kind == "hangup_verify")) {
            if (!snapshot(line, now)) { fail("invalid_CIND_snapshot"); return; } responseSeen = true;
        } else if (line == "OK") {
            if (!responseSeen) { fail("OK_before_required_data"); return; }
            Job done = pending; pending = {}; nextAt = now + .02;
            if (done.kind == "dial_preflight" && preflightCancelled) {
                preflightCancelled = false; dialQueued = false;
                events.push_back({"result", done.id, "dial_intent_cancelled; ATD_not_sent", false}); return;
            }
            if (stopping && (done.kind == "dial_preflight" || done.kind == "brsf" || done.kind == "cind_defs" || done.kind == "cind_initial" || done.kind == "cmer")) {
                events.push_back({"result", done.id, "cancelled_for_shutdown; no_followup_command", false}); return;
            }
            if (done.kind == "brsf") queue.push_front({"cind_defs", done.id});
            else if (done.kind == "cind_defs") queue.push_front({"cind_initial", done.id});
            else if (done.kind == "cind_initial") queue.push_front({"cmer", done.id});
            else if (done.kind == "cmer") { ready = true; stage = "slc_ready"; events.push_back({"result", done.id, "hfp_slc_ready", true}); }
            else if (done.kind == "dial_preflight") {
                if (!idle() || ring) { dialQueued = false; events.push_back({"result", done.id, "phone_not_idle; dial_not_sent", false}); }
                else queue.push_front({"dial", done.id});
            } else if (done.kind == "cancel_verify") {
                cancelledIntentNeedsSnapshot = false;
                events.push_back({"result", done.id, idleVerified ? "dial_intent_cancelled; fresh_idle_verified; CHUP_not_sent" : "dial_intent_cancelled; phone_not_idle; no_owned_call; CHUP_not_sent", idleVerified});
            } else if (done.kind == "hangup_preflight") {
                if (!ownDial && idleVerified) events.push_back({"result", done.id, "owned_call_already_ended; fresh_idle_verified; CHUP_not_sent", true});
                else if (ring || setup == 1 || ownershipContested || !ownDial) events.push_back({"result", done.id, "incoming_or_unowned_call; CHUP_not_sent", false});
                else if (hangupWriteAllowed(now)) queue.push_front({"hangup", done.id});
                else if (now < done.verifyUntil) { queue.push_front(done); nextAt = now + .25; }
                else events.push_back({"result", done.id, "owned_dial_lifecycle_unverified; CHUP_not_sent", false});
            } else if (done.kind == "dial") events.push_back({"result", done.id, "dial_accepted; active_call_not_yet_verified", true});
            else if (done.kind == "hangup") { queue.push_front({"hangup_verify", done.id, now + 5}); nextAt = now + .2; }
            else if (done.kind == "hangup_verify") {
                if (idleVerified) { ownDial = false; events.push_back({"result", done.id, "owned_call_ended_verified", true}); }
                else if (now < done.verifyUntil) { queue.push_front(done); nextAt = now + .25; }
                else events.push_back({"result", done.id, "CHUP_accepted_but_call_end_unverified", false});
            } else if (done.kind == "refresh") {
                events.push_back({"result", done.id, "status_refreshed", true});
            }
            if (ready && queue.empty()) stage = "slc_ready";
        }
    }
};
}
