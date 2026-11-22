# Operator presets

A preset tells the router how to ask one mobile operator for the prepaid balance and how to read the answer.
It is a data file in the image, `src/files/usr/share/lw/operators/<MCC-MNC>`, and the image ships one: `29702` (Telekom Montenegro).

With a preset for the SIM, `/balance` and `/status` in the Telegram chat show the balance, `LOW_BALANCE` in the profile turns on the weekly check and the low-balance alert (see [profile.md](profile.md)), and SMS from the operator's short codes show its name.
Without one (no file for the SIM, an IMSI that cannot be read, a file that fails the checks below) everything else works, and:

- the router sends no SMS of its own except replies to an admin's command;
- `/balance` and `/status` say `Balance: not available for this operator (<MCC-MNC>)`;
- senders show as numbers (with a `+` in front of long ones), without the operator's name;
- the weekly check sends nothing and the low-balance alert is off.

The router picks the file by the first 5 digits of the SIM's IMSI (the 3-digit country code and the first 2 digits of the network code) when the service `lw-notify` starts.
After a SIM swap restart it (`/etc/init.d/lw-notify restart`) or reboot.
The service runs only in an image with the Telegram bot or SMS control, so a preset does nothing without them.

## A preset for another operator

Write the file as described below and put it into `src/files/usr/share/lw/operators/` of your checkout; `./build.sh <name>` builds it into the image.
A build on GitHub builds a lonewrt release as it is, so there a preset has to be part of the release (see "Contributing" in [README.md](../README.md)).

To try a preset without a build, copy it to the running router and restart the service:

```sh
scp -O <MCC-MNC> root@<router>:/usr/share/lw/operators/
ssh root@<router> /etc/init.d/lw-notify restart
```

Such a copy is gone after the next flash or a reset with the button.

Nothing checks a preset at build time.
A file the router rejects leaves one line in its system log (`operator preset <MCC-MNC> rejected (<reason>), treated as no preset`, never a value): `logread -e 'operator preset'`.

## File format

Lines `KEY='value'`, empty lines and lines that start with `#`.
The router reads the file as data with a strict parser and never runs it as a shell script, so `$(...)`, backticks and `$VAR` are rejected, not expanded.
The parser is stricter than the one for profiles: no `'` inside a value, no spaces around `=`, before a key, before `#` or at the end of a line, and Unix line ends.
Every key below must appear once with a value; only `SHORT_CODES` may be left out (leave out the line: `SHORT_CODES=''` is rejected).
An unknown key, a repeated key, any other line, a value with a character outside the list, or a file over 4096 bytes rejects the whole file.

| Key | Meaning | Allowed |
|---|---|---|
| `OPERATOR_NAME` | the operator's name as the chat shows it (`Asked Telekom for the balance`, sender `Telekom 1466`) | up to 20 of letters, digits, space, `.`, `-`; starts with a letter or digit |
| `CURRENCY` | the currency shown after amounts | three capital letters, e.g. `EUR` |
| `BALANCE_QUERY_NUMBER` | where the balance query goes | digits with one optional leading `+`, at least 3 digits, up to 16 characters |
| `BALANCE_QUERY_TEXT` | the text of the query | up to 40 of letters, digits, space, `. , : _ -`; starts with a letter or digit |
| `BALANCE_REPLY_FROM` | the sender of the reply, exactly as the SMS carries it; a reply from any other sender is not read as a balance. The chat puts a `+` in front of a sender of 9 or more digits, which the SMS may not have | up to 16 of letters, digits, space, `. + _ -`; starts with a letter, digit or `+` |
| `BALANCE_REPLY_PATTERN` | what the reply looks like, see below | up to 80 of letters, digits, space and `: . , ; / ( ) = + { } _ -` |
| `SHORT_CODES` | optional: senders shown as `<OPERATOR_NAME> <code>`, space separated, one code is fine | letters, digits, space, up to 120 characters |

`LOW_BALANCE` in the profile is a number in `CURRENCY`; the preset has no threshold of its own.

## The reply pattern

The pattern describes the start of the first line of the reply; more text may follow.
Plain text matches itself, with capital and small letters told apart.
A space matches any white space (also none), and these placeholders stand for the parts that change:

| Placeholder | Matches | Use |
|---|---|---|
| `{amount}` | digits with an optional `.` or `,` part, e.g. `0.31`, `12,5` (shown with a dot) | exactly once |
| `{day}`, `{month}` | 1 or 2 digits each | both or neither, in either order (`{month}/{day}` for an operator that prints the month first); they give "valid until 5 Jan" in the chat |
| `{any}` | any text | as often as needed, with the rule below |

Any other brace rejects the preset.

`{any}` takes as much text as it can, so right before a number it would end inside the number: with `{any}.{amount}` the balance `12.50` would be read as `50`.
Between `{any}` and `{amount}`, `{day}` or `{month}` there must therefore be at least one character that is not a space, digit, dot or comma, otherwise the preset is rejected.
`{any}: {amount}`, `{any}EUR {amount}`, `{any}={amount}` and `Stanje {any} iznosi {amount}` are fine; `{any} {amount}`, `{any},{amount}` and `{any}{day}` are not.

The router reads an SMS as the balance when it comes from `BALANCE_REPLY_FROM`, its first line fits the pattern, and the router sent the query less than 10 minutes before (`/balance` or the weekly check).
After `/balance` the chat shows `Balance: <amount> <CURRENCY>`, with `valid until <day> <month>` when the pattern has a date.
The answer to the weekly check reaches the chat only when the amount has dropped below `LOW_BALANCE`; otherwise it is only kept for `/status`.
Any other SMS, also one that fits the pattern but that the router did not ask for, is forwarded as an ordinary SMS.

## Example

```
OPERATOR_NAME='Telekom'
CURRENCY='EUR'
BALANCE_QUERY_NUMBER='1466'
BALANCE_QUERY_TEXT='RACUN'
BALANCE_REPLY_FROM='1466'
BALANCE_REPLY_PATTERN='Imate: {amount} do {day}.{month}.'
SHORT_CODES='1466 1477'
```

This is `29702` (Telekom Montenegro), the preset the image ships: `RACUN` to `1466` and a reply like `Imate: 0.31 do 05.01.`.

## Writing a preset

1. Find the SIM's MCC-MNC. With the Telegram bot on, `/balance` names it: `Balance: not available for this operator (<MCC-MNC>)`. Otherwise read the IMSI on the router with `flock /tmp/lw-at.lock sms_tool -d /dev/ttyUSB2 at 'AT+CIMI'` and take its first 5 digits. The file name is exactly these 5 digits, no extension. With a 3-digit MNC (some US networks) the networks that share the first 5 digits share the preset.
2. From the operator's documentation or a real balance SMS of the owner, take the query number and text, the sender of the reply and one example reply. Do not invent them; an agent that has only a guess asks the owner.
3. Turn the example reply into a pattern: keep the fixed words, replace the balance with `{amount}`, the date with `{day}` and `{month}` if it has one, anything that varies between replies with `{any}`. Keep only characters from the table; if the operator's text has others (`:` and `,` are fine, `!`, `?`, `%` and non-ASCII are not), cut the pattern before them and let `{any}` cover the rest.
4. Write the file by the rules of "File format".
5. Try it on the router: copy the file as shown under "A preset for another operator" and send `/balance`. The chat should say that it asked the operator and, about a minute later, show `Balance: <amount> <CURRENCY>`. `not available for this operator` means the file was rejected or has another name: read the log line. A reply that arrives as an ordinary SMS means the sender or the pattern does not fit it. Only the real SIM shows the operator's exact words, its sender and how long the reply takes.
6. Put the file into `src/files/usr/share/lw/operators/` and build the image.

To test a preset without a router, use `tests/notify/preset.sh`: its block "another operator" writes a preset into a directory chosen with `LW_OPERATORS_DIR`, sets the fake SIM's IMSI and sends an example reply.
The block needs the setup at the top of that file, so change it in place: put in your values, your example reply and the texts you expect, then run `tests/rootfs/run.sh tests/notify/preset.sh`.
