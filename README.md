# modbus.sh
Simple Modbus TCP command line client.

Supports:
1) reading
2) writing
3) different endianess
4) multiplier
5) types
6) delay between connection and query

but not everything is tested, so anything might be broken. Please let me know if you encounter problems.

## Installing

Either git-clone or copy-paste the single file.

## Usage

The script uses Nix to declare its dependencies. If you already have suitable dependencies installed in the environment, feel free to remove the nix-shell she-bangs, or run the script like `sh modbus.sh` to skip the she-bangs.

```
> ./modbus.sh

Read and write Modbus registers

Usage: ./modbus.sh [-v] [-p <port:502>] [-u <unitid:255>] [-e <endianess:be>] [-d <delay:0>] [-m <multiplier:1>]
                   <host> <functioncode:1|2|3|4|5|6> <register> <type:uint16|int16|uint32|int32|float|(stringbytes)> [<newvalue>]

stringbytes : read this many bytes and interpret as text
endianess   : be or le
delay       : how many seconds to wait between connecting and sending command
multiplier  : multiply/divide the received/sent value by this decimal number
functioncode: 1 - Read Coil
              2 - Read Discrete Input
              3 - Read Holding Register
              4 - Read Input Register
              5 - Write Single Coil     (give value as 5th argument)
              6 - Write Single Register (give value as 5th argument)
```