/*
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
  Licensed under the Apache License v2.0 with Runtime Library Exception.
  See LICENSE file in the project root for full license terms.
*/

/*
 * blaise_time.c — date/time C shim for the Blaise RTL.
 *
 * Exposes six functions to the Pascal layer (all prefixed with _):
 *
 *   _TimeNow()            — nanoseconds since Unix epoch (CLOCK_REALTIME)
 *   _TimeLocalOffsetSecs()— local UTC offset in seconds (POSIX tm_gmtoff)
 *   _TimeSplit()          — UTC nanoseconds → calendar fields (UTC, no DST)
 *   _TimeJoin()           — calendar fields → UTC nanoseconds (UTC, no DST)
 *   _TimeIsLeapYear()     — 1 if leap year, 0 otherwise
 *   _TimeDaysInMonth()    — days in a given year/month (28/29/30/31)
 *
 * All arithmetic is in UTC.  Timezone-offset application is done in Pascal.
 */

#define _GNU_SOURCE
#include <stdint.h>
#include <time.h>
#include <string.h>

/* nanoseconds per second */
#define NS_PER_SEC INT64_C(1000000000)

/* ------------------------------------------------------------------ */

int64_t _TimeNow(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return (int64_t)ts.tv_sec * NS_PER_SEC + (int64_t)ts.tv_nsec;
}

/* Returns the system's current UTC offset in seconds.
   Positive east of UTC (e.g. +05:30 → 19800). */
int32_t _TimeLocalOffsetSecs(void)
{
    time_t t = time(NULL);
    struct tm lt;
    localtime_r(&t, &lt);
    /* tm_gmtoff is seconds east of UTC (POSIX extension) */
    return (int32_t)lt.tm_gmtoff;
}

/* Split nanoseconds-since-epoch (UTC) into calendar fields.
   All output fields are in UTC; no DST or offset applied. */
void _TimeSplit(int64_t nanos,
                int32_t *year, int32_t *month, int32_t *day,
                int32_t *hour, int32_t *min,   int32_t *sec,
                int32_t *nsec)
{
    int64_t whole_sec = nanos / NS_PER_SEC;
    int32_t nano_part = (int32_t)(nanos % NS_PER_SEC);
    /* Handle negative remainder for dates before epoch */
    if (nano_part < 0) {
        whole_sec -= 1;
        nano_part += (int32_t)NS_PER_SEC;
    }
    time_t t = (time_t)whole_sec;
    struct tm tm_out;
    gmtime_r(&t, &tm_out);
    *year  = tm_out.tm_year + 1900;
    *month = tm_out.tm_mon  + 1;
    *day   = tm_out.tm_mday;
    *hour  = tm_out.tm_hour;
    *min   = tm_out.tm_min;
    *sec   = tm_out.tm_sec;
    *nsec  = nano_part;
}

/* Join calendar fields (UTC) into nanoseconds-since-epoch.
   The nanosecond component is added after mktime conversion. */
int64_t _TimeJoin(int32_t year, int32_t month, int32_t day,
                  int32_t hour, int32_t min,   int32_t sec,
                  int32_t nsec)
{
    struct tm t;
    memset(&t, 0, sizeof(t));
    t.tm_year = year  - 1900;
    t.tm_mon  = month - 1;
    t.tm_mday = day;
    t.tm_hour = hour;
    t.tm_min  = min;
    t.tm_sec  = sec;
    /* timegm is the UTC equivalent of mktime (POSIX extension, widely available) */
    time_t epoch = timegm(&t);
    return (int64_t)epoch * NS_PER_SEC + (int64_t)nsec;
}

int32_t _TimeIsLeapYear(int32_t year)
{
    return ((year % 4 == 0) && (year % 100 != 0 || year % 400 == 0)) ? 1 : 0;
}

int32_t _TimeDaysInMonth(int32_t year, int32_t month)
{
    static const int32_t days[13] = {0,31,28,31,30,31,30,31,31,30,31,30,31};
    if (month == 2 && _TimeIsLeapYear(year))
        return 29;
    return days[month];
}
