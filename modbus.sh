#! /usr/bin/env nix-shell
#! nix-shell -i dash -I channel:nixos-23.11-small -p dash coreutils xxd netcat

set -eu

NCFLAGS=-W1 # Terminate after receiving 1 packet from the network

usage() {
    echo "Read and write Modbus registers"
    echo ""
    echo "Usage: $0 [-v] [-p <port:502>] [-u <unitid:255>] [-e <endianess:be>] [-d <delay:0>] [-m <multiplier:1>]"
    echo "                   <host> <functioncode:1|2|3|4|5|6> <register> <type:uint16|int16|uint32|int32|float|(stringbytes)> [<newvalue>]" 1>&2
    echo ""
    echo "stringbytes : read this many bytes and interpret as text"
    echo "endianess   : be or le"
    echo "delay       : how many seconds to wait between connecting and sending command"
    echo "multiplier  : multiply/divide the received/sent value by this decimal number"
    echo "functioncode: 1 - Read Coil"
    echo "              2 - Read Discrete Input"
    echo "              3 - Read Holding Register"
    echo "              4 - Read Input Register"
    echo "              5 - Write Single Coil     (give value as 5th argument)"
    echo "              6 - Write Single Register (give value as 5th argument)"
    exit 10
}

natural() { case "${OPTARG}" in ''|*[!0-9]*) return 1 ;; esac; }
posnumber() { case $OPTARG in (*[!0-9.]*) return 1 ;; esac; }

VERBOSE=0
PORT=502
UNITID=255
ENDIANESS="be"
DELAY=0
MULTIPLIER=1
while getopts ":p:u:e:d:m:v" o; do
    case "${o}" in
        v)
            VERBOSE=${OPTARG:-1}
        ;;
        p)
            PORT=${OPTARG}
            natural || usage
            ;;
        u)
            UNITID=${OPTARG}
            natural || usage
            ;;
        e)
            ENDIANESS=${OPTARG}
            ((ENDIANESS == "be" || ENDIANESS == "le")) || usage
            ;;
        d)
            DELAY=${OPTARG}
            natural || usage
            ;;
        m)
            MULTIPLIER=${OPTARG}
            posnumber || usage
            ;;
        *)
            usage
            ;;
    esac
done
shift $((OPTIND-1))

if [ $# -lt 4 ]; then usage; fi

host="$1"
functioncode="$2"
startaddress="$3"
type="$4"
newvalue="${5:-}"

# https://modbus.org/docs/Modbus_Messaging_Implementation_Guide_V1_0b.pdf

# -------------------- MBAP header
#                      -------------- PDU
# f9 e9 00 00 00 06 ff 03 9c 41 00 02
# ----- Transaction Identifier
#       ----- Protocol Identifier
#             ----- Length
#                   -- Unit Identifier
#                      -- function code
#                         ----- Register start address
#                               ----- Number of registers

txid="$(dd if=/dev/urandom count=2 bs=1 status=none | xxd -ps)"
protocolid="0000"
length="0006"
unitid="$(printf "%x" "$UNITID")"
regstartaddress="$(printf "%04x" "$startaddress")"
fcode="$(printf "%02x" "$functioncode")"

errorMessage() {
  case $1 in
    "01")
        echo "Illegal Function Code: The function code is unknown by the server"
        ;;
    "02") 
        echo "Illegal Data Address"
        ;;
    "03")
        echo "Illegal Data Value"
        ;;
    "04")
        echo "Server Failure: The server failed during the execution"
        ;;
    "05")
        echo "Acknowledge: The server accepted the service invocation but the service requires a relatively long time to execute. The server therefore returns only an acknowledgement of the service invocation receipt."
        ;;
    "06")
        echo "Server Busy: The server was unable to accept the MB Request PDU. The client application has the responsibility of deciding if and when to re-send the request."
        ;;
    "0A")
        echo "Gateway problem: Gateway paths not available."
        ;;
    "0B")
        echo "Gateway problem: The targeted device failed to respond. The gateway generates this exception"
        ;;
    *)
        echo "Unknown error code"
        ;;
  esac
}

typeLengthInHex() {
  case $1 in
    "uint16")
        echo "0001"
        ;;
    "int16")
        echo "0001"
        ;;
    "uint32")
        echo "0002"
        ;;
    "int32")
        echo "0002"
        ;;
    "float")
        echo "0002"
        ;;
    *) # n-byte string
        printf "%04x\n" "$type"
        ;;
  esac
}

serialize() {
  type="$1"
  read -r val
  case $type in
    "uint16")
        printf "%04x\n" "$val"
        ;;
    "int16")
        if [ "$val" -lt 0 ]; then
            printf "%04x\n" "$((val + 65536))"
        else
            printf "%04x\n" "$val"
        fi
        ;;
    "uint32")
        printf "%04x\n" "$val"
        ;;
    "int32")
        if [ "$val" -lt 0 ]; then
            printf "%04x\n" "$((val + 4294967297))"
        else
            printf "%04x\n" "$val"
        fi
        ;;
    "float")
        echo "not implemented" >&2 && exit 11
        ;;
    *) # n-byte string
        echo "$val" | xxd -r -p
        ;;
  esac
}

deserialize() {
  type="$1"
  read -r val
  case $type in
    "uint16")
        printf "%d\n" "$val"
        ;;
    "int16")
        if [ "$val" -gt 32767 ]; then
            printf "%d\n" "$((val - 65536))"
        else
            printf "%d\n" "$val"
        fi
        ;;
    "uint32")
        printf "%d\n" "$val"
        ;;
    "int32")
        if [ "$val" -gt 2147483646 ]; then
            printf "%d\n" "$((val - 4294967297))"
        else
            printf "%d\n" "$val"
        fi
        ;;
    "float")
        printf "%f\n" "$val"
        ;;
    *) # n-byte string
        echo "$val" | xxd -r -p
        ;;
  esac
}

multiply() {
    MULTIPLIER="$1"
    read -r x
    if [ "$MULTIPLIER" = "1" ]; then
        echo "$x"
    else
        echo "$x * $MULTIPLIER" | bc | {
            read -r x
            case $x in
                .*)
                    echo "0$x"
                    ;;
                -.*)
                    echo "-0.${x##*.}"
                    ;;
                *)
                    echo "$x"
                    ;;
            esac
        }
    fi
}

divide() {
    MULTIPLIER="$1"
    read -r x
    if [ "$MULTIPLIER" = "1" ]; then
        echo "$x"
    else
        echo "$x / $MULTIPLIER" | bc -l | {
            read -r x
            printf "%.0f\n" "$x"
        }
    fi
}

case $functioncode in
    "1" | "2" | "3" | "4")
      numRegistersOrValue="$(typeLengthInHex "$type")"
      ;;
    "5" | "6")
      numRegistersOrValue="$(echo "$newvalue" | divide "$MULTIPLIER" | serialize "$type")"
      ;;
    *)
      usage
      ;;
esac

tosend="${txid}${protocolid}${length}${unitid}${fcode}${regstartaddress}${numRegistersOrValue}"

if [ "$VERBOSE" = "1" ]; then
    echo "> $tosend" >&2
fi

{
    if [ "$DELAY" != "0" ]; then
        sleep "$DELAY"
    fi
    echo -n "$tosend" | xxd -r -p
} | nc $NCFLAGS "$host" "$PORT" | {
    if [ "$VERBOSE" = "1" ]; then
        _txid="$(dd bs=1 count=2 status=none | xxd -p)"
        _protocolid="$(dd bs=1 count=2 status=none | xxd -p)"
        _length="$(dd bs=1 count=2 status=none | xxd -p)"
    else
        _length="$(dd bs=1 count=2 skip=4 status=none | xxd -p)"
    fi
    _lengthDec="$(printf "%d" "0x$_length")"

    if [ "$_lengthDec" -gt 0 ]; then
      _unitid="$(dd bs=1 count=1 status=none | xxd -p)"
      _functioncode="$(dd bs=1 count=1 status=none | xxd -p)"
      if [ "$_functioncode" = "8$functioncode" ]; then
        _exceptioncode="$(dd bs=1 count=1 status=none | xxd -p)"
        echo "Error response: $_functioncode, exceptioncode: $_exceptioncode, message: $(errorMessage "$_exceptioncode")" >&2
        exit 1
      fi

      if [ "$VERBOSE" = "1" ]; then
        _valuelength="$(dd bs=1 count=1 status=none | xxd -p)"
        _value="$(dd count=1 bs="$((_lengthDec-3))" status=none | xxd -p)"
      else
        _valuelength=""
        _value="$(dd count=1 skip=1 bs="$((_lengthDec-3))" status=none | xxd -p)"
      fi
      
      if [ "$ENDIANESS" = "le" ]; then
        _value="$(echo -n "$_value" | sed 's/\(.\)\(.\)/\2\1/g')"
      fi
      if [ "$VERBOSE" = "1" ]; then
        echo "< ${_txid}${_protocolid}${_length}${_unitid}${_functioncode}${_valuelength}${_value}" >&2
      fi
      printf "%d\n" "0x$_value" | deserialize "$type"
    elif [ "$VERBOSE" = "1" ]; then
        echo "< ${_txid}${_protocolid}${_length}" >&2
    fi
} | multiply "$MULTIPLIER" | {
    read -r x
    echo "$x"
}
