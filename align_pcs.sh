#
# Usage: align_pcs.sh <0 | 1> [loopback]
#
# If PCS is not aligned, this script will perform PCS alignment on the specified QSFP port
#

# This Ethernet IP reset sequence and register map are from from page 128 of:
# https://docs.xilinx.com/viewer/book-attachment/KjOBPi3JqmLEeXdcXhXzyg/bRkBpLztI2LO~ZutVtlDmw

# Capture the command line parameters.  If $2 is "loopback", local-loopback will be enabled
p1=$1
p2=$2

# Determine the base address of the registers from the QSFP port number
if [ "$p1" == "0" ]; then
    QSFP_PORT=0
    ETH_BASE=0x10000
elif [ "$p1" == "1" ]; then
    QSFP_PORT=1
    ETH_BASE=0x20000
else
    echo "align_pcs requires a QSFP port number"
    exit 1
fi

# Ethernet configuration and status registers
            REG_ETH_RESET=$((ETH_BASE + 0x0004))
        REG_ETH_CONFIG_TX=$((ETH_BASE + 0x000C))
        REG_ETH_CONFIG_RX=$((ETH_BASE + 0x0014))
         REG_ETH_LOOPBACK=$((ETH_BASE + 0x0090))
          REG_ETH_STAT_RX=$((ETH_BASE + 0x0204))
REG_STAT_RX_TOTAL_PACKETS=$((ETH_BASE + 0x0608))
      REG_STAT_RX_BAD_FCS=$((ETH_BASE + 0x06C0))
  REG_ETH_RSFEC_CONFIG_IC=$((ETH_BASE + 0x1000))
     REG_ETH_RSFEC_CONFIG=$((ETH_BASE + 0x107C))
             REG_ETH_TICK=$((ETH_BASE + 0x02B0))


#==============================================================================
# This reads a PCI register and displays its value in decimal
#==============================================================================
read_reg()
{
  # Capture the value of the AXI register
  text=$(pcireg $1)

  # Extract just the first word of that text
  text=($text)

  # Convert the text into a number
  value=$((text))

  # Hand the value to the caller
  echo $value
}
#==============================================================================


#==============================================================================
# This enables RS-FEC and achieves PCS alignment.   If you pass it the
# keyword "loopback", internal transciever loopback mode will be enabled.
#
# Passed:  $1 = 0 or 1
#          $2 = "loopback" (or nothing)
#==============================================================================
enable_ethernet()
{
  # Our result starts out assuming we'll fail
  align_pcs_result=1

  # If we already have PCS lock, enable the transmitter and receiver and do
  # nothing else.  Issuing a reset to the Ethernet core while it already has
  # PCS lock does something that causes both the down-stream and upstream 
  # FIFOs to misbehave in unpleasant ways.
  status=$(read_reg $REG_ETH_STAT_RX)
  if [ $status -eq 3 ]; then
      pcireg $REG_ETH_CONFIG_TX 1
      pcireg $REG_ETH_CONFIG_RX 1
      align_pcs_result=0
      return
  fi

  # Disable the Ethernet transmitter
  pcireg $REG_ETH_CONFIG_TX 0

  # Enable RS-FEC indication and correction
  pcireg $REG_ETH_RSFEC_CONFIG_IC 3

  # Enable RS-FEC on both TX and RX
  pcireg $REG_ETH_RSFEC_CONFIG 3

  # Turn on local loopback so that we receive the packets we send
  test "$2" == "loopback" && pcireg $REG_ETH_LOOPBACK 1

  # Reset the Ethernet core to make the RS-FEC settings take effect
  pcireg $REG_ETH_RESET 0xC0000000
  pcireg $REG_ETH_RESET 0x00000000

  # Enable the Ethernet receiver
  pcireg $REG_ETH_CONFIG_RX 1

  # Enable the transmission of RFI (Remote Fault Indicator)
  pcireg $REG_ETH_CONFIG_TX 2

  # Wait for PCS alignment
  echo "Performing PCS alignment on QSFP${1}"
  prior_status=0
  aligned=0
  for n in {1..150}; 
  do

    # Fetch the alignment status
    status=$(read_reg $REG_ETH_STAT_RX)
    
    # Do we have full PCS alignment?
    if [ $status -eq 3 ]; then
      aligned=1
    fi    

    # Every time the status changes, display it
    if [ $status -ne $prior_status ]; then
      prior_status=$status
      printf "ETH_STAT_RX is 0x%04X" $status
      test $aligned -eq 1 && echo "" || echo " ..."
    fi

    # If we're aligned, we're done
    test $aligned -eq 1 && break;
    
    # Otherwise, wait a moment before trying again
    sleep .1
  done

  # Enable the Ethernet transmitter
  pcireg $REG_ETH_CONFIG_TX 1

  # Check to ensure that we have Ethernet PCS alignment
  if [ $aligned -eq 0 ]; then
      echo "PCS alignment failed!"
      return
  fi

  # Let the user know that all is well in Ethernet-land
  align_pcs_result=0
  echo "Ethernet enabled"
}
#==============================================================================


# Check to make sure the PCI bus sees our FPGA
reg=$(read_reg $REG_ETH_STAT_RX)
if [ $reg -eq $((0xFFFFFFFF)) ]; then
    echo "You forgot to issue a hot_reset"
    exit 1
fi

# Perform PCS alignment
enable_ethernet $QSFP_PORT $p2

# Tell the caller whether or not this worked
exit $align_pcs_result
