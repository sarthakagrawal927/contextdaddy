//! Minimal RFC 3339 parsing.
//!
//! Both agents stamp every record with a UTC timestamp in a fixed shape
//! (`2026-08-29T16:03:47.748Z`), so a full date-time crate would be a large
//! dependency for one narrow job. This parses that shape and nothing else.

/// Days from 1970-01-01 to the given civil date, using Howard Hinnant's
/// `days_from_civil` algorithm.
fn days_from_civil(year: i64, month: i64, day: i64) -> i64 {
    let year = if month <= 2 { year - 1 } else { year };
    let era = if year >= 0 { year } else { year - 399 } / 400;
    let year_of_era = year - era * 400;
    let day_of_year = (153 * (if month > 2 { month - 3 } else { month + 9 }) + 2) / 5 + day - 1;
    let day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
    era * 146_097 + day_of_era - 719_468
}

fn digits(bytes: &[u8]) -> Option<i64> {
    if bytes.is_empty() || !bytes.iter().all(u8::is_ascii_digit) {
        return None;
    }
    let mut value = 0i64;
    for byte in bytes {
        value = value * 10 + i64::from(byte - b'0');
    }
    Some(value)
}

/// Parses `YYYY-MM-DDTHH:MM:SS[.fff][Z|+HH:MM]` into epoch seconds.
pub fn epoch_seconds(stamp: &str) -> Option<f64> {
    let bytes = stamp.as_bytes();
    if bytes.len() < 19 || bytes[4] != b'-' || bytes[7] != b'-' {
        return None;
    }
    if bytes[10] != b'T' && bytes[10] != b' ' {
        return None;
    }
    if bytes[13] != b':' || bytes[16] != b':' {
        return None;
    }

    let year = digits(&bytes[0..4])?;
    let month = digits(&bytes[5..7])?;
    let day = digits(&bytes[8..10])?;
    let hour = digits(&bytes[11..13])?;
    let minute = digits(&bytes[14..16])?;
    let second = digits(&bytes[17..19])?;
    if !(1..=12).contains(&month) || !(1..=31).contains(&day) || hour > 23 || minute > 59 {
        return None;
    }

    let rest = &stamp[19..];
    let (fraction, rest) = match rest.strip_prefix('.') {
        Some(tail) => {
            let end = tail
                .find(|c: char| !c.is_ascii_digit())
                .unwrap_or(tail.len());
            let (frac_digits, remainder) = tail.split_at(end);
            let scaled = digits(frac_digits.as_bytes()).unwrap_or(0) as f64
                / 10f64.powi(frac_digits.len() as i32);
            (scaled, remainder)
        }
        None => (0.0, rest),
    };

    // Offsets are read so a non-UTC stamp is not silently shifted, even though
    // both agents write `Z` today.
    let offset_seconds = match rest.as_bytes().first() {
        None | Some(b'Z') | Some(b'z') => 0,
        Some(sign @ (b'+' | b'-')) => {
            let body = &rest[1..].replace(':', "");
            if body.len() < 4 {
                return None;
            }
            let hours = digits(&body.as_bytes()[0..2])?;
            let minutes = digits(&body.as_bytes()[2..4])?;
            let magnitude = hours * 3600 + minutes * 60;
            if *sign == b'+' {
                magnitude
            } else {
                -magnitude
            }
        }
        Some(_) => return None,
    };

    let days = days_from_civil(year, month, day);
    let seconds = days * 86_400 + hour * 3600 + minute * 60 + second - offset_seconds;
    Some(seconds as f64 + fraction)
}

/// Breaks epoch seconds into a UTC civil date and time.
pub fn civil(epoch: f64) -> (u16, u8, u8, u8, u8, u8) {
    let total = epoch.floor() as i64;
    let mut days = total.div_euclid(86_400);
    let seconds_of_day = total.rem_euclid(86_400);

    let mut year = 1970i64;
    loop {
        let length = if is_leap(year) { 366 } else { 365 };
        if days < length {
            break;
        }
        days -= length;
        year += 1;
    }
    let lengths = month_lengths(year);
    let mut month = 0usize;
    while month < 11 && days >= lengths[month] {
        days -= lengths[month];
        month += 1;
    }

    (
        year as u16,
        month as u8 + 1,
        days as u8 + 1,
        (seconds_of_day / 3600) as u8,
        ((seconds_of_day % 3600) / 60) as u8,
        (seconds_of_day % 60) as u8,
    )
}

fn is_leap(year: i64) -> bool {
    (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
}

fn month_lengths(year: i64) -> [i64; 12] {
    [
        31,
        if is_leap(year) { 29 } else { 28 },
        31,
        30,
        31,
        30,
        31,
        31,
        30,
        31,
        30,
        31,
    ]
}

/// Formats epoch seconds as `YYYY-MM-DD`, used for the default archive name.
pub fn date_stamp(epoch: f64) -> String {
    let (year, month, day, ..) = civil(epoch);
    format!("{year:04}-{month:02}-{day:02}")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_the_shape_both_agents_write() {
        assert_eq!(epoch_seconds("1970-01-01T00:00:00Z"), Some(0.0));
        assert_eq!(epoch_seconds("2026-08-29T16:03:47Z"), Some(1_788_019_427.0));
        let millis = epoch_seconds("2026-08-29T16:03:47.748Z").unwrap();
        assert!((millis - 1_788_019_427.748).abs() < 1e-6);
    }

    #[test]
    fn applies_a_numeric_offset() {
        let utc = epoch_seconds("2026-08-29T16:03:47Z").unwrap();
        assert_eq!(epoch_seconds("2026-08-29T18:03:47+02:00"), Some(utc));
        assert_eq!(epoch_seconds("2026-08-29T14:03:47-02:00"), Some(utc));
    }

    #[test]
    fn rejects_malformed_input() {
        assert_eq!(epoch_seconds(""), None);
        assert_eq!(epoch_seconds("not-a-date"), None);
        assert_eq!(epoch_seconds("2026-13-01T00:00:00Z"), None);
        assert_eq!(epoch_seconds("2026-08-29"), None);
    }

    #[test]
    fn breaks_an_epoch_into_civil_parts() {
        let epoch = epoch_seconds("2026-08-29T16:03:47Z").unwrap();
        assert_eq!(civil(epoch), (2026, 8, 29, 16, 3, 47));
        assert_eq!(civil(0.0), (1970, 1, 1, 0, 0, 0));
        assert_eq!(
            civil(epoch_seconds("2024-12-31T23:59:59Z").unwrap()),
            (2024, 12, 31, 23, 59, 59)
        );
    }

    #[test]
    fn round_trips_a_date_stamp() {
        let epoch = epoch_seconds("2026-08-29T16:03:47Z").unwrap();
        assert_eq!(date_stamp(epoch), "2026-08-29");
        assert_eq!(date_stamp(0.0), "1970-01-01");
        assert_eq!(
            date_stamp(epoch_seconds("2024-02-29T12:00:00Z").unwrap()),
            "2024-02-29"
        );
    }
}
