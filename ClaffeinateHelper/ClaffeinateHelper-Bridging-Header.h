#ifndef ClaffeinateHelper_Bridging_Header_h
#define ClaffeinateHelper_Bridging_Header_h

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOReturn.h>

// Private IOKit entry point that `pmset -a disablesleep` uses. It is exported
// by the IOKit framework but has no public header, so we declare the prototype
// here for Swift to call. Requires root. Link IOKit.framework.
IOReturn IOPMSetSystemPowerSetting(CFStringRef key, CFTypeRef value);

#endif /* ClaffeinateHelper_Bridging_Header_h */
