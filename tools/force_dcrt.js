/**
 * Attach to mobileactivationd and force DCRT reissue.
 * Usage: frida -U -n mobileactivationd -l force_dcrt.js
 */
'use strict';

function nsstr(s) {
  return ObjC.classes.NSString.stringWithString_(s);
}

function dumpDCRTState() {
  try {
    const daemon = ObjC.chooseSync(ObjC.classes.MobileActivationDaemon)[0];
    if (!daemon) {
      console.log('no MobileActivationDaemon instance');
      return null;
    }
    console.log('daemon =', daemon);

    if (daemon.respondsToSelector_(ObjC.selector('getDCRTStateWithCompletionBlock:'))) {
      const sem = Memory.alloc(8); // unused; use ObjC block sync via polling file
      daemon['- getDCRTStateWithCompletionBlock:'](new ObjC.Block({
        retType: 'void',
        argTypes: ['object'],
        implementation: function (state) {
          console.log('DCRTState =', state);
          try {
            console.log('DCRTState desc =', ObjC.Object(state).toString());
          } catch (e) {}
        }
      }));
    }

    if (daemon.respondsToSelector_(ObjC.selector('copyDCRTWithCompletionBlock:'))) {
      daemon['- copyDCRTWithCompletionBlock:'](new ObjC.Block({
        retType: 'void',
        argTypes: ['object', 'object'],
        implementation: function (dcrt, err) {
          console.log('copyDCRT dcrt=', dcrt, 'err=', err);
          try {
            if (dcrt) console.log('dcrt=', ObjC.Object(dcrt).toString());
            if (err) console.log('err=', ObjC.Object(err).toString());
          } catch (e) {}
        }
      }));
    }
    return daemon;
  } catch (e) {
    console.log('dumpDCRTState error', e);
    return null;
  }
}

function forceIssueDCRT() {
  const daemon = ObjC.chooseSync(ObjC.classes.MobileActivationDaemon)[0];
  if (!daemon) {
    console.log('FAIL: no daemon instance');
    return;
  }

  // Try options dict with DeleteExistingDCRT / IgnoreExistingDCRT
  const opts = ObjC.classes.NSMutableDictionary.dictionary();
  opts.setObject_forKey_(ObjC.classes.NSNumber.numberWithBool_(true), nsstr('DeleteExistingDCRT'));
  opts.setObject_forKey_(ObjC.classes.NSNumber.numberWithBool_(true), nsstr('IgnoreExistingDCRT'));

  console.log('calling issueDCRT with opts', opts);

  const done = Memory.alloc(4);
  done.writeU32(0);

  const block = new ObjC.Block({
    retType: 'void',
    argTypes: ['object'],
    implementation: function (err) {
      console.log('issueDCRT completion err=', err);
      try {
        if (err) console.log('err desc=', ObjC.Object(err).toString());
        else console.log('issueDCRT SUCCESS (nil error)');
      } catch (e) {
        console.log('completion parse err', e);
      }
      done.writeU32(1);
    }
  });

  // Selector: issueDCRT:withCompletionBlock:
  if (daemon.respondsToSelector_(ObjC.selector('issueDCRT:withCompletionBlock:'))) {
    daemon['- issueDCRT:withCompletionBlock:'](opts, block);
  } else {
    console.log('no issueDCRT:withCompletionBlock: — trying without options');
    // maybe issueDCRT takes bool?
    const methods = daemon.$ownMethods.filter(m => m.toLowerCase().indexOf('dcrt') >= 0);
    console.log('dcrt methods', methods);
  }

  // wait up to ~60s for completion
  const start = Date.now();
  const timer = setInterval(function () {
    if (done.readU32() === 1) {
      clearInterval(timer);
      console.log('DONE after', Date.now() - start, 'ms');
    } else if (Date.now() - start > 60000) {
      clearInterval(timer);
      console.log('TIMEOUT waiting for issueDCRT');
    }
  }, 500);
}

rpc.exports = {
  dump: dumpDCRTState,
  force: forceIssueDCRT
};

console.log('force_dcrt.js loaded — call rpc.exports.force() or auto-running');
dumpDCRTState();
setTimeout(forceIssueDCRT, 1000);
