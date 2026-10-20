defmodule ExNet do
  @moduledoc """
  Ethernet in hardware and on the BEAM, from one description.

  This part is the BEAM side: codecs for the frames and bit-exact reference
  models that the generated hardware is co-simulated against.

    * Frames: `ExNet.Ethernet` (802.1Q/802.1ad), `ExNet.IPv4`, `ExNet.UDP`,
      `ExNet.IGMP`, `ExNet.ARP`, fixed headers in `ExNet.Packets`
    * Models: `ExNet.CRC32`, `ExNet.MAC` (`Tx`, `Rx`), `ExNet.PCS.Code8b10b`,
      `ExNet.PCS.Base1000X`, `ExNet.PCS.AutoNeg`, `ExNet.PCS.Block66`,
      `ExNet.PCS.Scrambler`, `ExNet.PCS.BlockLock`, `ExNet.PCS.Base10GR`
    * Classification: `ExNet.Filter`
    * Test aid: `ExNet.Pcap`
  """
end
