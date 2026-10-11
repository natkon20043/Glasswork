#pragma once

#import <Foundation/Foundation.h>

/// With GLASSWORK_TIMING=1, prints how long after process start each start-up stage happened; otherwise nothing.
void GWStartupMark(NSString *label);
