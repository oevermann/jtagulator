{{
┌─────────────────────────────────────────────────┐
│ JTAGulator                                      │
│                                                 │
│ Author: Joe Grand                               │                     
│ Copyright (c) 2013-2014 Grand Idea Studio, Inc. │
│ Web: http://www.grandideastudio.com             │
│                                                 │
│ Distributed under a Creative Commons            │
│ Attribution 3.0 United States license           │
│ http://creativecommons.org/licenses/by/3.0/us/  │
└─────────────────────────────────────────────────┘

Program Description:

The JTAGulator is a hardware tool that assists in identifying on-chip
debug/programming interfaces from test points, vias, component pads,
and/or connectors on a target device.

Refer to the project page for more details:

http://www.jtagulator.com

Each interface object contains the low-level routines and operational details
for that particular on-chip debugging interface. This keeps the main JTAGulator
object a bit cleaner. 

Command listing is available in the DAT section at the end of this file.

}}


CON
  _clkmode = xtal1 + pll16x
  _xinfreq = 5_000_000           ' 5 MHz clock * 16x PLL = 80 MHz system clock speed 
  _stack   = 100                 ' Ensure we have this minimum stack space available        

  ' Serial terminal
  ' Control characters
  LF    = 10  ''LF: Line Feed
  CR    = 13  ''CR: Carriage Return
  CAN   = 24  ''CAN: Cancel (Ctrl-X) 
  
  ' JTAGulator I/O pin definitions
  PROP_SDA      = 29
  PROP_SCL      = 28  
  LED_R         = 27   ' Bi-color Red/Green LED, common cathode
  LED_G         = 26
  DAC_OUT       = 25   ' PWM output for DAC
  TXS_OE        = 24   ' Output Enable for TXS0108E level translators

  ' JTAGulator general constants  
  MAX_CHAN      = 24   ' Maximum number of pins/channels the JTAGulator hardware provides (P23..P0)
  MAX_INPUT_LEN = 12   ' Maximum length of command
  
  ' JTAG/IEEE 1149.1
  MAX_NUM_JTAG  = 32   ' Maximum number of devices allowed in a single JTAG chain

  ' UART
  MAX_LEN_UART  = 16   ' Maximum number of bytes to receive from target
   
  
VAR                   ' Globally accessible variables
  byte vCmd[MAX_INPUT_LEN + 1]  ' Buffer for command input string
  long vTargetIO      ' Target I/O voltage (for example, 18 = 1.8V)
  
  long jTDI           ' JTAG pins (must stay in this order)
  long jTDO
  long jTCK
  long jTMS
  long jTRST
  long jNUM           ' Number of devices in JTAG chain
  
  long uTXD           ' UART pins (as seen from the target) (must stay in this order)
  long uRXD
  long uBAUD
  byte uSTR[MAX_INPUT_LEN + 1]
  
  
OBJ
  ser           : "PropSerial"        ' Serial communication for user interface (modified version of built-in Parallax Serial Terminal)
  rr            : "RealRandom"        ' Random number generation (Chip Gracey, http://obex.parallax.com/object/498) 
  jtag          : "PropJTAG"          ' JTAG/IEEE 1149.1 low-level functions
  uart          : "JDCogSerial"       ' UART/Asynchronous Serial communication engine (Carl Jacobs, http://obex.parallax.com/object/298)
  
  
PUB main 
  System_Init                   ' Initialize system/hardware
  JTAG_Init                     ' Initialize JTAG-specific items
  UART_Init                     ' Initialize UART-specific items
  ser.Str(@InitHeader)          ' Display header; uses string in DAT section.

  ' Start command receive/process cycle
  repeat
    TXSDisable                     ' Disable level shifter outputs (high-impedance)
    LEDGreen                       ' Set status indicator to show that we're ready
    ser.Str(String(CR, LF, ":"))   ' Display command prompt
    ser.StrInMax(@vCmd,  MAX_INPUT_LEN) ' Wait here to receive a carriage return terminated string or one of MAX_INPUT_LEN bytes (the result is null terminated) 
    LEDRed                              ' Set status indicator to show that we're processing a command

    if (strsize(@vCmd) == 1)  ' We currently only support single character commands...
      case vCmd[0]              ' Check the first character of the input string
        "U", "u":                 ' Identify UART pinout
          if (vTargetIO == -1)
            ser.Str(@ErrTargetIOVoltage)
          else
            UART_Scan

        "P", "p":                 ' UART passthrough
          if (vTargetIO == -1)
            ser.Str(@ErrTargetIOVoltage)
          else
            UART_Passthrough
                        
        "I", "i":                 ' Identify JTAG pinout (IDCODE Scan)
          if (vTargetIO == -1)
            ser.Str(@ErrTargetIOVoltage)
          else
            IDCODE_Scan
         
        "B", "b":                 ' Identify JTAG pinout (BYPASS Scan)
          if (vTargetIO == -1)
            ser.Str(@ErrTargetIOVoltage)
          else
            BYPASS_Scan
            
        "D", "d":                 ' Get JTAG Device IDs (Pinout already known)
          if (vTargetIO == -1)
            ser.Str(@ErrTargetIOVoltage)
          else
            IDCODE_Known
         
        "T", "t":                 ' Test BYPASS (TDI to TDO) (Pinout already known)
          if (vTargetIO == -1)
            ser.Str(@ErrTargetIOVoltage)
          else
            BYPASS_Known
                          
        "V", "v":                 ' Set target I/O voltage
          Set_Target_IO_Voltage
          
        "R", "r":                 ' Read all channels (input)
          if (vTargetIO == -1)
            ser.Str(@ErrTargetIOVoltage)
          else
            Read_IO_Pins
         
        "W", "w":                 ' Write all channels (output)
          if (vTargetIO == -1)
            ser.Str(@ErrTargetIOVoltage)
          else
            Write_IO_Pins
         
        "J", "j":                 ' Display JTAGulator version information
          ser.Str(@VersionInfo)      ' Uses string in DAT section.
          
        "H", "h":                 ' Display list of available commands
          ser.Str(@CommandList)      ' Uses string in DAT section.
                  
        other:                    ' Unknown command    
          ser.Str(String(CR, LF, "?"))
    else
      ser.Str(String(CR, LF, "?"))
         

CON {{ JTAG COMMANDS }}

PRI JTAG_Init
  rr.start         ' Start RealRandom cog (used during BYPASS test)
  
 
PRI IDCODE_Scan | value, value_new, num_chan, ctr    ' Identify JTAG pinout (IDCODE Scan)
  num_chan := Get_Channels(3)   ' Get the number of channels to use
  if (num_chan == -1)           ' If value is out of range, skip function
    return
  Display_Permutations(num_chan, 3)  ' TDO, TCK, TMS

  ser.Str(@MsgPressSpacebarToBegin)
  if (ser.CharIn <> " ")
    ser.Str(@ErrIDCODEAborted)
    return

  ser.Str(@MsgJTAGulating)
  TXSEnable     ' Enable level shifter outputs

  ' We assume the IDCODE is the default DR after reset
  ' Pin enumeration logic based on JTAGenum (http://deadhacker.com/2010/02/03/jtag-enumeration/)
  jTDI := PROP_SDA                     ' TDI isn't used when we're just shifting data from the DR. Set TDI to a temporary pin so it doesn't interfere with enumeration.
 
  repeat jTDO from 0 to (num_chan-1)   ' For every possible pin permutation (except TDI and TRST)...
    repeat jTCK from 0 to (num_chan-1)
      if (jTCK == jTDO)
        next
      repeat jTMS from 0 to (num_chan-1)
        if (jTMS == jTCK) or (jTMS == jTDO)
          next
  
        if (ser.RxCount)  ' Abort scan if any key is pressed
          longfill(@jTDI, 0, 5) ' Clear JTAG pinout
          ser.RxFlush          
          ser.Str(@ErrIDCODEAborted)
          return

        Set_Pins_High(num_chan)               ' Set currently selected channels to output HIGH (in case there are active low signals that may affect operation, like TRST# or SRST#) 
        jtag.Config(jTDI, jTDO, jTCK, jTMS)   ' Configure JTAG pins
        jtag.Get_Device_IDs(1, @value)        ' Try to get Device ID by reading the DR      
        if (value <> -1) and (value & 1)      ' Ignore if received Device ID is 0xFFFFFFFF or if bit 0 != 1
          Display_JTAG_Pins                   ' Display current JTAG pinout
          
          ' Now try to determine if the TRST# pin is being used on the target
          repeat jTRST from 0 to (num_chan-1)     ' For every remaining channel...
            if (jTRST == jTMS) or (jTRST == jTCK) or (jTRST == jTDO) or (jTMS == jTDI)
              next
              
            if (ser.RxCount)  ' Abort scan if any key is pressed
              longfill(@jTDI, 0, 5) ' Clear JTAG pinout
              ser.RxFlush
              ser.Str(@ErrIDCODEAborted)
              return
      
            dira[jTRST] := 1  ' Set current pin to output
            outa[jTRST] := 0  ' Output LOW
                 
            jtag.Get_Device_IDs(1, @value_new)  ' Try to get Device ID again by reading the DR
            if (value_new <> value)             ' If the new value doesn't match what we already have, then the current pin may be a reset line.
              ser.Str(String("TRST#: "))          ' So, display the pin number
              ser.Dec(jTRST)
              ser.Str(String(CR, LF))
                     
            outa[jTRST] := 1  ' Bring the current pin HIGH when done
        
        ' Progress indicator
        ++ctr
        Display_Progress(ctr, 100)

  longfill(@jTDI, 0, 5) ' Clear JTAG pinout 
  ser.Str(String(CR, LF, "IDCODE scan complete!"))


PRI BYPASS_Scan | value, value_new, num_chan, ctr      ' Identify JTAG pinout (BYPASS Scan)
  num_chan := Get_Channels(4)   ' Get the number of channels to use
  if (num_chan == -1)           ' If value is out of range, skip function
    return
  Display_Permutations(num_chan, 4)  ' TDI, TDO, TCK, TMS
    
  ser.Str(@MsgPressSpacebarToBegin)
  if (ser.CharIn <> " ")
    ser.Str(@ErrBYPASSAborted)
    return

  ser.Str(@MsgJTAGulating)
  TXSEnable     ' Enable level shifter outputs

  repeat jTDI from 0 to (num_chan-1)        ' For every possible pin permutation (except TRST#)...
    repeat jTDO from 0 to (num_chan-1)
      if (jTDO == jTDI)  ' Ensure each pin number is unique
        next
      repeat jTCK from 0 to (num_chan-1)
        if (jTCK == jTDO) or (jTCK == jTDI)
          next
        repeat jTMS from 0 to (num_chan-1)
          if (jTMS == jTCK) or (jTMS == jTDO) or (jTMS == jTDI)
            next
                      
          if (ser.RxCount)  ' Abort scan if any key is pressed
            longfill(@jTDI, 0, 5) ' Clear JTAG pinout
            ser.RxFlush
            ser.Str(@ErrBYPASSAborted)
            return

          Set_Pins_High(num_chan)                     ' Set currently selected channels to output HIGH (in case there is a signal on the target that needs to be held HIGH, like TRST# or SRST#)
          jtag.Config(jTDI, jTDO, jTCK, jTMS)         ' Configure JTAG pins
          value := jtag.Detect_Devices
          if (value)
            Display_JTAG_Pins                         ' Display current JTAG pinout
            
            ' Now try to determine if the TRST# pin is being used on the target
            repeat jTRST from 0 to (num_chan-1)     ' For every remaining channel...
              if (jTRST == jTMS) or (jTRST == jTCK) or (jTRST == jTDO) or (jTMS == jTDI)
                next
              
              if (ser.RxCount)  ' Abort scan if any key is pressed
                longfill(@jTDI, 0, 5) ' Clear JTAG pinout
                ser.RxFlush
                ser.Str(@ErrBYPASSAborted)
                return
      
              dira[jTRST] := 1  ' Set current pin to output
              outa[jTRST] := 0  ' Output LOW

              value_new := jtag.Detect_Devices
              if (value_new <> value)           ' If the new value doesn't match what we already have, then the current pin may be a reset line.
                ser.Str(String("TRST#: "))        ' So, display the pin number
                ser.Dec(jTRST)
                ser.Str(String(CR, LF))
                     
              outa[jTRST] := 1  ' Bring the current pin HIGH when done

            ser.Str(String("Number of devices detected: "))
            ser.Dec(value)
            ser.Str(String(CR, LF))

        ' Progress indicator
          ++ctr
          Display_Progress(ctr, 10)
        
  longfill(@jTDI, 0, 5) ' Clear JTAG pinout        
  ser.Str(String(CR, LF, "BYPASS scan complete!"))

  
PRI IDCODE_Known | value, id[MAX_NUM_JTAG], i        ' Get JTAG Device IDs (Pinout already known)
  if (Set_JTAG(0) == -1)  ' Ask user for the known JTAG pinout
    return                  ' Abort if error
    
  if (Set_NUM == -1)      ' Ask user for the number of devices in JTAG chain
    return                  ' Abort if error 

  TXSEnable                                   ' Enable level shifter outputs
  ser.Str(@MsgChannelsSetHigh)
  Set_Pins_High(MAX_CHAN)                     ' In case there is a signal on the target that needs to be held HIGH, like TRST# or SRST#
  jtag.Config(jTDI, jTDO, jTCK, jTMS)         ' Configure JTAG pins
  
  jtag.Get_Device_IDs(jNUM, @id)              ' We assume the IDCODE is the default DR after reset
  repeat i from 0 to (jNUM-1)                 ' For each device in the chain...
    value := id[i]
    if (jNUM == 1)
      Display_Device_ID(value, 0)                ' Display Device ID of the only device in the chain
    else
      Display_Device_ID(value, i + 1)            ' Display Device ID of current device in the chain   
     
  jTDI := 0      ' Reset TDI to an actual channel value (it was set to a temporary pin value to avoid contention)
  ser.Str(String(CR, LF, "IDCODE listing complete!"))


PRI BYPASS_Known | dataIn, dataOut   ' Test BYPASS (TDI to TDO) (Pinout already known)
  if (Set_JTAG(1) == -1)  ' Ask user for the known JTAG pinout
    return                  ' Abort if error
    
  if (Set_NUM == -1)      ' Ask user for the number of devices in JTAG chain
    return                  ' Abort if error
    
  TXSEnable                                   ' Enable level shifter outputs
  ser.Str(@MsgChannelsSetHigh)
  Set_Pins_High(MAX_CHAN)                     ' In case there is a signal on the target that needs to be held HIGH, like TRST# or SRST#
  jtag.Config(jTDI, jTDO, jTCK, jTMS)         ' Configure JTAG pins
  
  dataIn := rr.random                         ' Get 32-bit random number to use as the BYPASS pattern
  dataOut := jtag.Bypass_Test(jNUM, dataIn)   ' Run the BYPASS instruction 
    
  ' Display input/output data and check if they match
  ser.Str(String(CR, LF, "Pattern in to TDI:    "))
  ser.Bin(dataIn, 32)   ' Display value as binary characters (0/1)

  ser.Str(String(CR, LF, "Pattern out from TDO: "))
  ser.Bin(dataOut, 32)  ' Display value as binary characters (0/1)

  if (dataIn == dataOut)
    ser.Str(String(CR, LF, "Match!"))
  else
    ser.Str(String(CR, LF, "No Match!"))

       
PRI Set_NUM : err | value          ' Set the number of devices in chain
  ser.Str(String(CR, LF, "Enter number of devices in JTAG chain ["))
  ser.Dec(jNUM)               ' Display current value
  ser.Str(String("]: "))
  value := Get_Decimal_Pin    ' Get new value from user
  if (value == -1)            ' If carriage return was pressed...      
    value := jNUM               ' Keep current setting
  if (value < 1) or (value > MAX_NUM_JTAG)   ' If entered value is out of range, abort
    ser.Str(@ErrOutOfRange)
    return -1

  jNUM := value


PRI Set_JTAG(getTDI) : err | xtdi, xtdo, xtck, xtms, buf, c     ' Set JTAG configuration to known values
  if (getTDI == 1)          
    ser.Str(String(CR, LF, "Enter new TDI pin ["))
    ser.Dec(jTDI)               ' Display current value
    ser.Str(String("]: "))
    xtdi := Get_Decimal_Pin     ' Get new value from user
    if (xtdi == -1)             ' If carriage return was pressed...      
      xtdi := jTDI                ' Keep current setting
    if (xtdi < 0) or (xtdi > MAX_CHAN-1)  ' If entered value is out of range, abort
      ser.Str(@ErrOutOfRange)
      return -1
  else
    ser.Str(String(CR, LF, "TDI not needed to retrieve Device ID."))
    xtdi := PROP_SDA            ' Set TDI to a temporary pin so it doesn't interfere with enumeration

  ser.Str(String(CR, LF, "Enter new TDO pin ["))
  ser.Dec(jTDO)               ' Display current value
  ser.Str(String("]: "))
  xtdo := Get_Decimal_Pin     ' Get new value from user
  if (xtdo == -1)             ' If carriage return was pressed...      
    xtdo := jTDO                ' Keep current setting
  if (xtdo < 0) or (xtdo > MAX_CHAN-1)  ' If entered value is out of range, abort
    ser.Str(@ErrOutOfRange)
    return -1

  ser.Str(String(CR, LF, "Enter new TCK pin ["))
  ser.Dec(jTCK)               ' Display current value
  ser.Str(String("]: "))
  xtck := Get_Decimal_Pin     ' Get new value from user
  if (xtck == -1)             ' If carriage return was pressed...      
    xtck := jTCK                ' Keep current setting
  if (xtck < 0) or (xtck > MAX_CHAN-1)  ' If entered value is out of range, abort
    ser.Str(@ErrOutOfRange)
    return -1

  ser.Str(String(CR, LF, "Enter new TMS pin ["))
  ser.Dec(jTMS)               ' Display current value
  ser.Str(String("]: "))
  xtms := Get_Decimal_Pin     ' Get new value from user
  if (xtms == -1)             ' If carriage return was pressed...      
    xtms := jTMS                ' Keep current setting
  if (xtms < 0) or (xtms > MAX_CHAN-1)  ' If entered value is out of range, abort
    ser.Str(@ErrOutOfRange)
    return -1       

  ' Make sure that the pin numbers are unique
  ' Set bit in a long corresponding to each pin number
  buf := 0
  buf |= (1 << xtdi)
  buf |= (1 << xtdo)
  buf |= (1 << xtck)
  buf |= (1 << xtms)
  
  ' Count the number of bits that are set in the long
  c := 0
  repeat 32
    c += (buf & 1)
    buf >>= 1

  if (c <> 4)         ' If there are not exactly 4 bits set (TDI, TDO, TCK, TMS), then we have a collision
    ser.Str(@ErrPinCollision)
    return -1
  else                ' If there are no collisions, update the globals with the new values
    jTDI := xtdi      
    jTDO := xtdo
    jTCK := xtck
    jTMS := xtms
    

PRI Display_JTAG_Pins
  ser.Str(String(CR, LF, "TDI: "))
  if (jTDI => MAX_CHAN)     ' TDI isn't used during an IDCODE Scan (we're not shifting any data into the target), so it can't be determined
    ser.Str(String("N/A"))  
  else
    ser.Dec(jTDI)
    
  ser.Str(String(CR, LF, "TDO: "))
  ser.Dec(jTDO)

  ser.Str(String(CR, LF, "TCK: "))
  ser.Dec(jTCK)

  ser.Str(String(CR, LF, "TMS: "))
  ser.Dec(jTMS)
  
  ser.Str(String(CR, LF))


PRI Display_Device_ID(value, num)
  ser.Str(String(CR, LF, "Device ID"))
  if (num > 0)
    ser.Str(String(" #"))
    ser.Dec(num)
  ser.Str(String(": "))
   
  ' Display value as binary characters (0/1) based on IEEE Std. 1149.1 2001 Device Identification Register structure
  {{ IEEE Std. 1149.1 2001
     Device Identification Register
   
     MSB                                                                          LSB
     ┌───────────┬──────────────────────┬───────────────────────────┬──────────────┐
     │  Version  │      Part Number     │   Manufacturer Identity   │   Fixed (1)  │
     └───────────┴──────────────────────┴───────────────────────────┴──────────────┘
        31...28          27...12                  11...1                   0
  }}
  ser.Bin(Get_Bit_Field(value, 31, 28), 4)      ' Version
  ser.Char(" ")
  ser.Bin(Get_Bit_Field(value, 27, 12), 16)     ' Part Number
  ser.Char(" ")  
  ser.Bin(Get_Bit_Field(value, 11, 1), 11)      ' Manufacturer Identity
  ser.Char(" ")
  ser.Bin(Get_Bit_Field(value, 0, 0), 1)        ' Fixed (should always be 1)

  ' Display value as hexadecimal
  ser.Str(String(" (0x"))
  ser.Hex(value, 8)
  ser.Str(String(")"))

  if (value <> -1) and (value & 1)      ' If Device ID value is valid
    ' Extended decoding
    ' Not all vendors use these fields as specified
    ser.Str(String(CR, LF, "-> Manufacturer ID: 0x"))
    ser.Hex(Get_Bit_Field(value, 11, 1), 3)
    ser.Str(String(CR, LF, "-> Part Number: 0x"))
    ser.Hex(Get_Bit_Field(value, 27, 12), 4)
    ser.Str(String(CR, LF, "-> Version: 0x"))
    ser.Hex(Get_Bit_Field(value, 31, 28), 1)
    ser.Str(String(CR, LF))
  else                                   
    ser.Str(String(CR, LF, "-> Invalid ID!", CR, LF))  ' Otherwise, device ID is invalid (0xFFFFFFFF or if bit 0 != 1), so let the user know
                                                    

CON {{ UART COMMANDS }}

PRI UART_Init
  bytefill (@uSTR, 0, MAX_INPUT_LEN + 1)  ' Clear input string buffer


PRI UART_Scan  | value, num_chan, baud_idx, i, j, ctr, xval, xstr[MAX_INPUT_LEN >> 2 + 1], data[MAX_LEN_UART >> 2]     ' Identify UART pinout
 ' Get user string to send during UART discovery
  ser.Str(String(CR, LF, "Enter text string to output (prefix with \x for hex) ["))
  if (uSTR[0] == 0)
    ser.Str(String("CR"))  ' Default to a CR if string hasn't been set yet  
  else
    ser.Str(@uSTR)         ' If a previous string exists, display it
  ser.Str(String("]: "))

  ser.StrInMax(@xstr, MAX_INPUT_LEN) ' Get input from user
  i := strsize(@xstr)
  if (i <> 0)                        ' If input was anything other than a CR
    ' Make sure each character in the string is printable ASCII
    repeat j from 0 to (i-1)
      if (byte[@xstr][j] < $20) or (byte[@xstr][j] > $7E)
        ser.Str(@ErrOutOfRange)  ' If the string contains invalid (non-printable) characters, abort
        return
             
    bytemove(@uSTR, @xstr, i)             ' Move the new string into the uSTR global
    bytefill(@uSTR+i, 0, MAX_INPUT_LEN-i) ' Fill the remainder of the string with NULL, in case it's shorter than the last 

  ' Check string for the \x escape sequence. If it exists, the desired string is a series of hex bytes
  if (byte[@uSTR][0] == "\" and byte[@uSTR][1] == "x")
    if (byte[@uSTR][10] <> 0) or (ser.StrToBase(@uSTR+2, 16) == 0)  ' If the string is too long or it's a NULL byte
      ser.Str(@ErrOutOfRange)  ' If the hex string is too long, abort
      return    
    xval := ser.StrToBase(@uSTR+2, 16)
  else
    xval := 0
               
  num_chan := Get_Channels(2)   ' Get the number of channels to use
  if (num_chan == -1)           ' If value is out of range, skip function
    return
   
  Display_Permutations(num_chan, 2) ' TXD, RXD 

  ser.Str(@MsgPressSpacebarToBegin)
  if (ser.CharIn <> " ")
    ser.Str(@ErrUARTAborted)
    return

  ser.Str(@MsgJTAGulating)
  TXSEnable     ' Enable level shifter outputs
  
  repeat uTXD from 0 to (num_chan-1)   ' For every possible pin permutation...
    repeat uRXD from 0 to (num_chan-1)
      if (uRXD == uTXD)
        next

      repeat baud_idx from 0 to (constant(BaudRateEnd - BaudRate) >> 2) - 1   ' For every possible baud rate in BaudRate table...
        if (ser.RxCount)        ' Abort scan if any key is pressed
          longfill(@uTXD, 0, 3)   ' Clear UART pinout + settings
          ser.RxFlush
          ser.Str(@ErrUARTAborted)
          return
      
        uBAUD := BaudRate[baud_idx]        ' Store current baud rate into uBAUD variable
        UART.Start(|<uTXD, |<uRXD, uBAUD)  ' Configure UART
        UART.RxFlush                       ' Flush receive buffer

        if (xval == 0)                     ' If the user string is ASCII
          UART.str(@uSTR)                    ' Send string to target
          UART.tx(CR)                        ' Send carriage return to target
        else                               ' Otherwise, send hex characters one at a time
          if (xval & $ff000000)              ' Ignore MSBs if they are NULL
            UART.tx(xval >> 24)
            UART.tx(xval >> 16)
            UART.tx(xval >> 8)
            UART.tx(xval & $ff)
          elseif (xval & $ff0000)
            UART.tx(xval >> 16)
            UART.tx(xval >> 8)
            UART.tx(xval & $ff)
          elseif (xval & $ff00)            
            UART.tx(xval >> 8)
            UART.tx(xval & $ff)
          else
            UART.tx(xval & $ff)                    

        i := 0
        repeat while (i < MAX_LEN_UART)    ' Check for a response from the target and grab up to MAX_LEN_UART bytes
          value := UART.RxTime(20)           ' Wait up to 20ms to receive a byte from the target
          if (value < 0)                     ' If there's no data, exit the loop
            quit
          byte[@data][i++] := value          ' Store the byte in our array and try for more!

        repeat until (UART.RxTime(20) < 0)   ' Wait here until the target has stopped sending data
        
        if (i > 0)                           ' If we've received any data...
          Display_UART_Pins                    ' Display current UART pinout
          ser.Str(String("Data: "))            ' Display the data in ASCII
          repeat value from 0 to (i-1)                  
            if (byte[@data][value] < $20) or (byte[@data][value] > $7E) ' If the byte is an unprintable character 
              ser.Char(".")                                               ' Print a . instead
            else
              ser.Char(byte[@data][value])

          ser.Str(String(" [ "))
          repeat value from 0 to (i-1)        ' Display the data in hexadecimal
            ser.Hex(byte[@data][value], 2)
            ser.Char(" ")
          ser.Str(String("]", CR, LF))

    ' Progress indicator
      ++ctr
      Display_Progress(ctr, 1)
        
  longfill(@uTXD, 0, 3) ' Clear UART pinout + settings
  UART.Stop
  ser.Str(String(CR, LF, "UART scan complete!"))


PRI UART_Passthrough | value, echo    ' UART/terminal passthrough
  if (Set_UART == -1)     ' Ask user for the known UART configuration
    return                ' Abort if error

  ser.Str(String(CR, LF, "Enable local echo? [y/N]: "))   ' Display command prompt
  ser.StrInMax(@vCmd,  MAX_INPUT_LEN) ' Wait here to receive a carriage return terminated string or one of MAX_INPUT_LEN bytes (the result is null terminated) 
  if (strsize(@vCmd) =< 1)            ' We're only looking for a single character (or NULL, which will have a string size of 0)
    case vCmd[0]                        ' Check the first character of the input string
        0, "N", "n":                      ' If the byte is NULL, we can assume the user only entered a CR
          echo := 0                         ' Disable echo flag
        "Y", "y":
          echo := 1                         ' Enable echo flag
        other:
          ser.Str(@ErrOutOfRange)
          return
  else
    ser.Str(@ErrOutOfRange)
    return
      
  TXSEnable                          ' Enable level shifter outputs
  UART.Start(|<uTXD, |<uRXD, uBAUD)  ' Configure UART

  ser.Str(String(CR, LF, "Entering UART passthrough! Press Ctrl-X to abort...", CR, LF))

  repeat until (value == CAN)  ' stay in terminal passthrough until cancel value is received
    repeat while ((value := UART.rxcheck) => 0) ' if the target buffer contains data...
      ser.Char(value)                             ' ...display it

    repeat while (ser.RxCount > 0)              ' if the JTAGulator buffer contains data...
      if (echo == 0)                              ' if local echo is off...
        value := ser.CharInNoEcho                   ' ...get the data (but don't echo it)
      else
        value := ser.CharIn                         ' ...get the data (and echo it)
         
      if (value <> CAN)                             
        UART.tx(value)                            ' and send to the target (as long as it isn't the cancel value)

  ser.RxFlush
  UART.RxFlush
  UART.Stop
  ser.Str(String(CR, LF, "UART passthrough complete!"))
    

PRI Set_UART : err | xtxd, xrxd, xbaud            ' Set UART configuration to known values
  ser.Str(String(CR, LF, "Enter new TXD pin ["))
  ser.Dec(uTXD)               ' Display current value
  ser.Str(String("]: "))
  xtxd := Get_Decimal_Pin     ' Get new value from user
  if (xtxd == -1)             ' If carriage return was pressed...      
    xtxd := uTXD                ' Keep current setting
  if (xtxd < 0) or (xtxd > MAX_CHAN-1)  ' If entered value is out of range, abort
    ser.Str(@ErrOutOfRange)
    return -1

  ser.Str(String(CR, LF, "Enter new RXD pin ["))
  ser.Dec(uRXD)               ' Display current value
  ser.Str(String("]: "))
  xrxd := Get_Decimal_Pin     ' Get new value from user
  if (xrxd == -1)             ' If carriage return was pressed...      
    xrxd := uRXD                ' Keep current setting
  if (xrxd < 0) or (xrxd > MAX_CHAN-1)  ' If entered value is out of range, abort
    ser.Str(@ErrOutOfRange)
    return -1

  ser.Str(String(CR, LF, "Enter new baud rate ["))
  ser.Dec(uBAUD)              ' Display current value
  ser.Str(String("]: "))
  xbaud := Get_Decimal_Pin    ' Get new value from user
  if (xbaud == -1)            ' If carriage return was pressed...      
    xbaud := uBAUD              ' Keep current setting
  if (xbaud < 1) or (xbaud > BaudRate[(constant(BaudRateEnd - BaudRate) >> 2) - 1])  ' If entered value is out of range, abort
    ser.Str(@ErrOutOfRange)
    return -1

  ' Make sure that the pin numbers are unique
  if (xtxd == xrxd)  ' If we have a collision
    ser.Str(@ErrPinCollision)
    return -1
  else                ' If there are no collisions, update the globals with the new values
    uTXD := xtxd      
    uRXD := xrxd
    uBAUD := xbaud


PRI Display_UART_Pins
  ser.Str(String(CR, LF, "TXD: "))
  ser.Dec(uTXD)
  ser.Str(String(CR, LF, "RXD: "))
  ser.Dec(uRXD)
  ser.Str(String(CR, LF, "Baud: "))
  ser.Dec(uBAUD)
  ser.Str(String(CR, LF)) 


CON {{ GENERAL COMMANDS }}
    
PRI Set_Target_IO_Voltage | value
  ser.Str(String(CR, LF, "Current target I/O voltage: "))
  Display_Target_IO_Voltage

  ser.Str(String(CR, LF, "Enter new target I/O voltage (1.2 - 3.3, 0 for off): "))
  value := Get_Decimal_Pin   ' Receive decimal value (including 0)
  if (value == 0)                              
    vTargetIO := -1
    DACOutput(0)               ' DAC output off 
    ser.Str(String(CR, LF, "Target I/O voltage off!"))
  elseif (value < 12) or (value > 33)
    ser.Str(@ErrOutOfRange)
  else
    vTargetIO := value
    DACOutput(VoltageTable[vTargetIO - 12])     ' Look up value that corresponds to the actual desired voltage and set DAC output
    ser.Str(String(CR, LF, "New target I/O voltage set: "))
    Display_Target_IO_Voltage    ' Print a confirmation of newly set voltage
    ser.Str(String(CR, LF, "Ensure VADJ is NOT connected to target!"))


PRI Display_Target_IO_Voltage
  if (vTargetIO == -1)
    ser.Str(String("Undefined"))
  else
    ser.Dec(vTargetIO / 10)      ' Display vTargetIO as an x.y value
    ser.Char(".")
    ser.Dec(vTargetIO // 10)


PRI Display_Progress(ctr, mod)      ' Display a progress indicator during JTAGulation (every mod counts)
  if ((ctr // mod) == 0)
    ser.Char(".")  ' Print character
    !outa[LED_G]   ' Toggle LED between red and yellow


PRI Read_IO_Pins | value, count              ' Read all channels (input)  
  ser.Char(CR)
  
  TXSEnable               ' Enable level shifter outputs
  dira[23..0]~            ' Set P23-P0 as inputs
  value := ina[23..0]     ' Read all channels

  ser.Str(String(CR, LF, "CH23..CH0: "))
  
  ' Display value as binary characters (0/1)
  repeat count from 16 to 0 step 8
    ser.Bin(value >> count, 8)
    ser.Char(" ")
 
  ' Display value as hexadecimal
  ser.Str(String(" ("))
  ser.Hex(value, 6)
  ser.Str(String(")"))    

  
PRI Write_IO_Pins : err | value, count       ' Write all channels (output)
  ser.Str(String(CR, LF, "Enter value to output (in hex): "))
  value := ser.HexIn      ' Receive carriage return terminated string of characters representing a hexadecimal value

  if (value & $ff000000)
    ser.Str(@ErrOutOfRange)
    return -1
      
  TXSEnable               ' Enable level shifter outputs
  dira[23..0]~~           ' Set P23-P0 as outputs
  outa[23..0] := value    ' Write value to output
  
  ser.Str(String(CR, LF, "CH23..CH0 set to: "))
  repeat count from 16 to 0 step 8
    ser.Bin(value >> count, 8)
    ser.Char(" ")
    
  ' Display value as hexadecimal
  ser.Str(String(" ("))
  ser.Hex(value, 6)
  ser.Str(String(")"))    

  ser.Str(String(CR, LF, "Press any key when done..."))
  ser.CharIn       ' Wait for any key to be pressed before finishing routine (and disabling level translators)

    
PRI Set_Pins_High(num) | i     ' Set channels to output HIGH
  repeat i from 0 to (num-1)   ' From CH0..CH(num-1)
    dira[i] := 1
    outa[i] := 1

           
PRI Get_Channels(min_chan) : value | buf
{
  Ask user for the number of JTAGulator channels actually hooked up
  
  Parameters: min_chan = Minimum number of pins/channels required (varies with on-chip debug interface)
}
  ser.Str(String(CR, LF, "Enter number of channels to use ("))
  ser.Dec(min_chan)       ' Display minimum channels
  ser.Str(String(" - "))
  ser.Dec(MAX_CHAN)       ' Display maximum channels
  ser.Str(String("): "))

  value := ser.DecIn                              ' Receive carriage return terminated string of characters representing a decimal value
  if (value < min_chan) or (value > MAX_CHAN)
    ser.Str(@ErrOutOfRange)
    value := -1
  else
    ser.Str(String(CR, LF, "Ensure connections are on CH"))
    ser.Dec(value-1)
    ser.Str(String("..CH0."))


PRI Get_Decimal_Pin : value | buf       ' Get a decimal number from the user (including number 0, which prevents us from using standard Parallax Serial Terminal routines)
  buf := ser.CharIn
  
  case buf
    "0".."9":                           ' If the byte entered is an actual number
      value := (buf - "0")                      ' Convert it into a decimal value
      repeat while ((buf := ser.CharIn) <> CR)  ' Get subsequent bytes until a carriage return is received 
        if (buf => "0") and (buf =< "9")          ' If the byte entered is still an actual number (ignore all non-digit characters)
          value *= 10                                ' Keep converting into a decimal value
          value += (buf - "0")                      
    CR:
      value := -1     ' Carriage return
    other:
      value := -2     ' Invalid character


PRI Get_Bit_Field(value, highBit, lowBit) : fieldVal | mask, bitnum    ' Return the bit field within a specified range. Based on a fork by Bob Heinemann (https://github.com/BobHeinemann/jtagulator/blob/master/JTAGulator.spin)
  repeat bitNum from lowBit to highBit
    mask |= |<bitNum

  fieldVal := (value & mask) >> (highBit - (highBit - lowBit))


PRI Display_Permutations(n, r) | value, i
{{  http://www.mathsisfun.com/combinatorics/combinations-permutations-calculator.html

    Order important, no repetition
    Total pins (n)
    Number of pins needed (r)
    Number of permutations: n! / (n-r)!
}}
  ser.Str(String(CR, LF, "Possible permutations: "))

  ' Thanks to Rednaxela of #tymkrs for the optimized calculation
  value := 1
  repeat i from (n - r + 1) to n
    value *= i    

  ser.Dec(value)

     
PRI System_Init
  ' Set direction of I/O pins
  ' Output
  dira[TXS_OE] := 1
  dira[LED_R]  := 1        
  dira[LED_G]  := 1
   
  ' Set I/O pins to the proper initialization values
  TXSDisable      ' Disable level shifter outputs (high-impedance)
  LedYellow       ' Yellow = system initialization

  ' Set up PWM channel for DAC output
  ' Based on Andy Lindsay's PropBOE D/A Converter (http://learn.parallax.com/node/107)
  ctra[30..26]  := %00110       ' Set CTRMODE to PWM/duty cycle (single ended) mode
  ctra[5..0]    := DAC_OUT      ' Set APIN to desired pin
  dira[DAC_OUT] := 1            ' Set pin as output
  DACOutput(0)                  ' DAC output off 

  vTargetIO := -1               ' Target voltage is undefined 
  ser.Start(115_200)            ' Start serial communications                                                                                    


PRI DACOutput(dacval)
  spr[10] := dacval * 16_777_216    ' Set counter A frequency (scale = 2^32 / 256)  

    
PRI TXSEnable
  dira[23..0]~                      ' Set P23-P0 as inputs to avoid contention when driver is enabled. Pin directions will be configured by other functions as needed.
  outa[TXS_OE] := 1
  waitcnt(clkfreq / 100_000 + cnt)  ' 10uS delay (must wait > 200nS for TXS0108E one-shot circuitry to become operational)


PRI TXSDisable
  outa[TXS_OE] := 0

    
PRI LedOff
  outa[LED_R] := 0 
  outa[LED_G] := 0

  
PRI LedGreen
  outa[LED_R] := 0 
  outa[LED_G] := 1

  
PRI LedRed
  outa[LED_R] := 1 
  outa[LED_G] := 0

  
PRI LedYellow
  outa[LED_R] := 1 
  outa[LED_G] := 1

               
DAT
InitHeader    byte CR, LF, LF
              byte "                                    UU  LLL", CR, LF                                     
              byte " JJJ  TTTTTTT AAAAA  GGGGGGGGGGG   UUUU LLL   AAAAA TTTTTTTT OOOOOOO  RRRRRRRRR", CR, LF 
              byte " JJJJ TTTTTTT AAAAAA GGGGGGG       UUUU LLL  AAAAAA TTTTTTTT OOOOOOO  RRRRRRRR", CR, LF  
              byte " JJJJ  TTTT  AAAAAAA GGG      UUU  UUUU LLL  AAA AAA   TTT  OOOO OOO  RRR RRR", CR, LF   
              byte " JJJJ  TTTT  AAA AAA GGG  GGG UUUU UUUU LLL AAA  AAA   TTT  OOO  OOO  RRRRRRR", CR, LF   
              byte " JJJJ  TTTT  AAA  AA GGGGGGGGG UUUUUUUU LLLLLLLL AAAA  TTT OOOOOOOOO  RRR RRR", CR, LF   
              byte "  JJJ  TTTT AAA   AA GGGGGGGGG UUUUUUUU LLLLLLLLL AAA  TTT OOOOOOOOO  RRR RRR", CR, LF   
              byte "  JJJ  TT                  GGG             AAA                         RR RRR", CR, LF   
              byte " JJJ                        GG             AA                              RRR", CR, LF   
              byte "JJJ                          G             A                                 RR", CR, LF, LF 
              byte "           Welcome to JTAGulator. Press 'H' for available commands.", CR, LF, 0

VersionInfo   byte CR, LF, "JTAGulator FW 1.2.3x", CR, LF
              byte "Designed by Joe Grand, Grand Idea Studio, Inc.", CR, LF
              byte "Main: jtagulator.com", CR, LF
              byte "Source: github.com/grandideastudio/jtagulator", CR, LF
              byte "Support: http://www.parallax.com/support", 0

CommandList   byte CR, LF, "JTAG Commands:", CR, LF
              byte "I   Identify JTAG pinout (IDCODE Scan)", CR, LF
              byte "B   Identify JTAG pinout (BYPASS Scan)", CR, LF
              byte "D   Get Device ID(s)", CR, LF
              byte "T   Test BYPASS (TDI to TDO)", CR, LF
              byte CR, LF, "UART Commands:", CR, LF
              byte "U   Identify UART pinout", CR, LF
              byte "P   UART passthrough", CR, LF              
              byte CR, LF, "General Commands:", CR, LF
              byte "V   Set target I/O voltage (1.2V to 3.3V)", CR, LF
              byte "R   Read all channels (input)", CR, LF  
              byte "W   Write all channels (output)", CR, LF
              byte "J   Display version information", CR, LF
              byte "H   Display available commands", 0

' Any messages repeated more than once are placed here to save space
MsgPressSpacebarToBegin     byte CR, LF, "Press spacebar to begin (any other key to abort)...",0
MsgJTAGulating              byte CR, LF, "JTAGulating! Press any key to abort...", 0
MsgChannelsSetHigh          byte CR, LF, "All other channels set to output HIGH.", CR, LF, 0

ErrTargetIOVoltage          byte CR, LF, "Target I/O voltage must be defined!", 0
ErrOutOfRange               byte CR, LF, "Value out of range!", 0
ErrPinCollision             byte CR, LF, "Pin numbers must be unique!", 0
ErrIDCODEAborted            byte CR, LF, "IDCODE scan aborted!", 0
ErrBYPASSAborted            byte CR, LF, "BYPASS scan aborted!", 0
ErrUARTAborted              byte CR, LF, "UART scan aborted!", 0
                                                               
' Look-up table to correlate actual I/O voltage (1.2V to 3.3V) to DAC value
' Full DAC range is 0 to 3.3V @ 256 steps = 12.89mV/step
'                  1.2  1.3  1.4  1.5  1.6  1.7  1.8  1.9  2.0  2.1  2.2  2.3  2.4  2.5  2.6  2.7  2.8  2.9  3.0  3.1  3.2  3.3           
VoltageTable  byte  93, 101, 109, 116, 124, 132, 140, 147, 155, 163, 171, 179, 186, 194, 202, 210, 217, 225, 233, 241, 248, 255

' Look-up table of accepted values for use with UART identification
BaudRate      long  75, 110, 150, 300, 900, 1200, 1800, 2400, 3600, 4800, 7200, 9600, 14400, 19200, 28800, 31250 {MIDI}, 38400, 57600, 76800, 115200, 153600, 230400, 250000 {DMX}, 307200
BaudRateEnd

      