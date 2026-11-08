# Operator presets

Everything that belongs to one mobile operator lives in a preset, a data file `src/files/usr/share/lw/operators/<MCC-MNC>`.
The file name is the first 5 digits of the SIM's IMSI: the 3-digit country code and the first 2 digits of the network code, e.g. `29702`.
The service reads the IMSI from the modem (`AT+CIMI`) and loads the file of that name.
Until the modem answers, it reads the IMSI again every minute.
The preset is chosen when the service starts, so after a SIM swap restart it (`/etc/init.d/lw-notify restart`) or reboot.
Presets are in the image, so a new one needs a new build.

A SIM without a preset (no file, an unreadable IMSI, a file that does not pass the checks below) gets the safe behaviour:

- the router sends no SMS of its own except replies to an admin's command;
- `/balance` and `/status` say `Balance: not available for this operator (<MCC-MNC>)`;
- senders show as the plain number (`+` kept on long numbers);
- the weekly balance job sends nothing and the low-balance alert is off.

A rejected file leaves one line in the system log (`operator preset <MCC-MNC> rejected (<reason>)`, never a value).

## File format

Lines `KEY='value'` (single quotes, no `'` inside, no spaces around `=`), blank lines and lines starting with `#`.
The file is read as data by a strict parser and never run as a shell script, so `$(...)`, backticks, `;` and `$VAR` are rejected, not expanded.
Every key below must appear once, except `SHORT_CODES`, which may be left out.
An unknown key, a repeated key, any other line, a value with a character outside the list, or a file over 4096 bytes rejects the whole file.

| Key | Meaning | Allowed |
|---|---|---|
| `OPERATOR_NAME` | the operator's name as the chat shows it (`ask Telekom for the balance`, label `Telekom 1466`) | up to 20 of letters, digits, space, `.`, `-`; starts with a letter or digit |
| `CURRENCY` | three capital letters, shown after amounts | `EUR`, `USD`, ... |
| `BALANCE_QUERY_NUMBER` | where the balance query goes | digits with one optional leading `+`, at least 3 digits, up to 16 characters |
| `BALANCE_QUERY_TEXT` | the text of the query | up to 40 of letters, digits, space, `. , : _ -`; starts with a letter or digit |
| `BALANCE_REPLY_FROM` | the sender of the reply; a reply from any other sender is not read as a balance | up to 16 of letters, digits, space, `. + _ -` |
| `BALANCE_REPLY_PATTERN` | what the reply looks like, see below | up to 80 of letters, digits, space and `: . , ; / ( ) = + { } _ -` |
| `SHORT_CODES` | optional: senders shown as `<OPERATOR_NAME> <code>`, space separated, one code is fine | letters, digits, space, up to 120 characters |

`LOW_BALANCE` in the profile is a number in `CURRENCY`; the preset has no threshold of its own.

## The reply pattern

The pattern describes the start of the first line of the reply (the rest of the text may follow).
Plain text matches itself, a space matches any white space (also none), and these placeholders stand for parts that change:

| Placeholder | Matches | Use |
|---|---|---|
| `{amount}` | digits with an optional `.` or `,` part, e.g. `0.31`, `12,5` | exactly once |
| `{day}`, `{month}` | 1 or 2 digits | both or neither; they give "credit valid until 5 Jan" in the chat |
| `{any}` | any text | optional, as often as needed; put a fixed word between `{any}` and a number placeholder (`Stanje {any} iznosi {amount}`), otherwise the preset is rejected |

Any other brace is an error.
The date is taken as day then month in the order the placeholders appear, so `{month}/{day}` works for operators that print the month first.
A reply whose sender is `BALANCE_REPLY_FROM` and whose first line fits the pattern is shown with `= Balance <amount> <CURRENCY>` (and the date when the pattern has one) and feeds `/status`, the low-balance alert and `LOW_BALANCE`.
A reply that does not fit is forwarded as a plain SMS.

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

1. Find the SIM's MCC-MNC: the first 5 digits of the IMSI (`sms_tool`/`AT+CIMI` on the router, or the SIM's operator code from the operator's documentation). The file name is exactly these 5 digits, no extension. With a 3-digit MNC (some US networks) the file still takes only the first 5 digits, so networks that share them share the preset.
2. From the operator's documentation or a real balance SMS of the owner, take the query number and text, the sender of the reply and one example reply. Do not invent them; ask the owner if you only have a guess.
3. Turn the example reply into a pattern: keep the fixed words, replace the balance with `{amount}`, the date with `{day}` and `{month}` if it has one, anything that varies between replies with `{any}`. Keep only characters from the table; if the operator's text has others (`:` and `,` are fine, `!`, `?`, `%` and non-ASCII are not), cut the pattern before them and let `{any}` cover the rest.
4. Write the file with the keys of the table. Check by hand: no `'` inside a value, each key once, nothing but `KEY='value'` and `#` lines.
5. Test it without the router: `tests/notify/preset.sh` has a block "another operator" that writes a preset into a directory chosen with `LW_OPERATORS_DIR`, sets the fake SIM's IMSI and sends an example reply; copy it with your values and the real example reply, then run `tests/rootfs/run.sh tests/notify/<your test>.sh`.
6. Build the image. The new file is in the overlay as `/usr/share/lw/operators/<MCC-MNC>` (mode 0644).

What only the live router can show: the real reply of the operator to the query (its exact words, its sender, how long it takes).
Run `/balance` once on the real SIM and check that the chat shows `= Balance ...`.
