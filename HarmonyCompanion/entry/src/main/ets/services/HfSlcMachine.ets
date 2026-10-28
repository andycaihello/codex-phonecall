// Pure control parser: no Bluetooth, audio, phone, timer, or filesystem API.
export class HfSlcMachine {
  state: string = 'idle';
  stage: number = 0;
  reason: string = '';
  agFeatures: string = '';
  cindDefinitions: string = '';
  cindValues: string = '';
  receivedLines: string[] = [];
  private pending: string = '';
  private responseSeen: boolean = false;
  private expiresAt: number = 0;

  start(): void { this.state = 'ready'; }

  takeCommand(now: number): string {
    if (this.state !== 'ready') { return ''; }
    let command = '';
    if (this.stage === 0) { command = 'AT+BRSF=0\r'; }
    else if (this.stage === 1) { command = 'AT+CIND=?\r'; }
    else if (this.stage === 2) { command = 'AT+CIND?\r'; }
    else if (this.stage === 3) { command = 'AT+CMER=3,0,0,1\r'; }
    if (command.length > 0) {
      this.pending = '';
      this.state = 'waiting';
      this.responseSeen = this.stage === 3;
      this.expiresAt = now + 12000;
    }
    return command;
  }

  feed(bytes: Uint8Array, now: number): void {
    this.receivedLines = [];
    if (this.checkTimeout(now) || this.state === 'stopped' || this.state === 'failed') { return; }
    for (let i = 0; i < bytes.length; i++) {
      const value = bytes[i];
      if (value === 10 || value === 13) {
        if (this.pending.length > 0) {
          const line = this.pending.trim();
          this.pending = '';
          this.line(line);
          if (this.state === 'failed') { return; }
        }
      } else if (value >= 32 && value < 127) {
        this.pending += String.fromCharCode(value);
        if (this.pending.length > 512) { this.fail('control line length limit'); return; }
      } else {
        this.fail('non-ASCII control data');
        return;
      }
    }
  }

  private line(line: string): void {
    let safeLine = `Redacted control line (${line.length} characters)`;
    const features = /^\+BRSF:\s*\d{1,10}$/.test(line);
    const definitions = /^\+CIND:\s*\("[a-z][a-z0-9]{0,23}",\s*\([0-9,\- ]+\)\)(\s*,\s*\("[a-z][a-z0-9]{0,23}",\s*\([0-9,\- ]+\)\))*$/.test(line);
    const values = /^\+CIND:\s*\d{1,3}(\s*,\s*\d{1,3}){0,31}$/.test(line);
    if (line === 'OK' || line === 'ERROR' || line === 'RING' || features || definitions || values ||
      /^\+VG[SM]\s*[:=]\s*\d{1,2}$/.test(line)) { safeLine = line; }
    this.receivedLines.push(safeLine);
    if (this.receivedLines.length > 32) { this.receivedLines.shift(); }
    if (line === 'ERROR' || /^\+CME ERROR:/.test(line)) { this.fail('AG returned ERROR'); return; }
    // A response already buffered before the next command was written cannot acknowledge that command.
    if (this.state !== 'waiting') { return; }
    if (this.stage === 0 && features) { this.agFeatures = line; this.responseSeen = true; }
    else if (this.stage === 1 && definitions) { this.cindDefinitions = line; this.responseSeen = true; }
    else if (this.stage === 2 && values) { this.cindValues = line; this.responseSeen = true; }
    else if (line === 'OK') {
      if (!this.responseSeen) { this.fail('OK received before required stage response'); return; }
      this.stage++;
      this.state = this.stage === 4 ? 'complete' : 'ready';
    }
  }

  checkTimeout(now: number): boolean {
    if (this.state === 'waiting' && now >= this.expiresAt) { this.fail('12-second stage timeout'); }
    return this.state === 'failed';
  }

  stop(reason: string): void { this.state = 'stopped'; this.reason = reason; this.pending = ''; }

  private fail(reason: string): void { this.state = 'failed'; this.reason = reason; this.pending = ''; }
}
