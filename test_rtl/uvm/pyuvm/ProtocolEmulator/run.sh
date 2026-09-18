    #!/bin/bash

    # Source the cocotb_env environment
    echo "        [PYUVM] Sourcing cocotb_env environment..."
    source cocotb_env/bin/activate
    if [ $? -ne 0 ]; then
        echo "        [PYUVM] FAIL: Failed to source cocotb_env environment. Exiting script."
        exit 1
    fi

    # Copy original rtl here
    cp ${PWD}/../../../../rtl/ProtocolEmulator.v .

    # Build pyUVM
    make SIM=icarus

    # Remove testbench
    rm ProtocolEmulator.v