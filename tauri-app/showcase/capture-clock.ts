import data from './real-data.json';
// An explicitly dated capture, never a fabricated live reading. This keeps the
// original 30-minute eligibility and calendar logic anchored to collection time.
const NativeDate=Date;
const capturedMillis=data.capturedAtUnix*1000;
class CaptureDate extends NativeDate {
  constructor(...args:unknown[]){super((Reflect.construct(NativeDate,args.length?args:[capturedMillis]) as Date).getTime());}
  static now(){return capturedMillis;}
}
window.Date=CaptureDate as DateConstructor;
