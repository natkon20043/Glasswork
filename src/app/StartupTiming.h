#pragma once

#import <Foundation/Foundation.h>

/// With GLASSWORK_TIMING=1 in the environment, prints how long after the process started each
/// stage of start-up happened. Does nothing otherwise.
void GWStartupMark(NSString *label);
