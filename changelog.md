0.0.8.0 2026-07-07
==================
- utillinux -> util-linux

0.0.7.0 2025-10-21
==================
- add gocmd01{,nodryrun}_

0.0.6.0 2025-03-19
==================
- fix info{,f}_ to not return !=0 if info is not written

0.0.5.0 2024-07-15
==================
- add signal warning in exit warning

0.0.4.0 2024-07-11
==================
- slightly cleaner check() (code cleanup, no user change)
- add better commentary to capture
- capture uses local -n for varname, thus avoiding potential name clashes
  (such clashes will still elicit a warning, but won't actually break; I think)
- capture will die if called with __varname__ as its varname
- some error code tidying

0.0.3.0 2023-06-07
==================
- add --return-zero to _go; and thus gocmd01{,nodryrun}

0.0.2.0 2023-06-06
==================
- +gocmdnodryexitzero

0.0.1.0 2023-06-03
==================
- +CMD[wc]
- upgrade check{,_} to use all the subsequent arguments for printing

0.0.0.0 2023-02-17
==================
- initial import, from rc/nixpkgs/scripts
