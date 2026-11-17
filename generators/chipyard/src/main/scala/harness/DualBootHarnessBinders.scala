package chipyard.harness

import scala.collection.mutable

import chisel3._
import chisel3.util._

import sifive.blocks.devices.uart.{UARTPortIO, UARTParams}
import testchipip.uart.{UARTAdapter}

import chipyard.iobinders._

/** One UART line shared by the console UART and UART-TSI (dual boot).
  *
  * {{{
  * line RX ─┬──────────────────────────────► console UART rxd
  *          └─► Mux(tsiBlock, 1, rxd) ─────► UART-TSI rxd
  * line TX ◄── consoleTxd && tsiTxd                (idle = 1, so AND is safe)
  * tsiBlock = GPIO[gatePin].oe && GPIO[gatePin].oval
  * }}}
  *
  * Harness binders run once per port, so the console UART, UART-TSI and GPIO
  * ports each see only their own port. This object hands all three the same
  * set of wires, one per (harness, chip). The wires default to "line idle,
  * gate open", so a config that lacks one of the ports still elaborates.
  *
  * `attach` connects the far end of the line: a pty in simulation, the board
  * pins on an FPGA. It is called once, when the wires are created, with the
  * TX bit the harness should send and returns the RX bit it received.
  */
object SharedUART {
  type Attach = (HasHarnessInstantiators, Bool) => Bool

  class Wires(th: HasHarnessInstantiators, attach: Attach) {
    val consoleTxd = WireDefault(true.B).suggestName("shared_uart_console_txd")
    val tsiTxd     = WireDefault(true.B).suggestName("shared_uart_tsi_txd")
    val tsiBlock   = WireDefault(false.B).suggestName("shared_uart_tsi_block")
    val rxd        = WireDefault(attach(th, consoleTxd && tsiTxd)).suggestName("shared_uart_rxd")
    def tsiRxd: Bool = Mux(tsiBlock, true.B, rxd)
  }

  private val wires = mutable.WeakHashMap[HasHarnessInstantiators, mutable.Map[Int, Wires]]()

  def apply(th: HasHarnessInstantiators, chipId: Int, attach: Attach): Wires =
    wires.getOrElseUpdate(th, mutable.Map()).getOrElseUpdate(chipId, new Wires(th, attach))

  /** Simulation: the line ends in a pty (printed as "UARTn is here ... /dev/pts/N"). */
  def simPty(baud: BigInt): Attach = (th, txd) => {
    val line = Wire(new UARTPortIO(UARTParams(address = 0)))
    line.txd := txd
    val div = (th.getHarnessBinderClockFreqHz / baud.toDouble).toInt
    UARTAdapter.connect(Seq(line), div, forcePty = true)
    line.rxd
  }
}

/** Console UART, UART-TSI and the gate GPIO on one line; see [[SharedUART]].
  *
  * @param attach  far end of the line (SharedUART.simPty, or board pins)
  * @param gatePin GPIO pin that closes the TSI gate when driven high
  */
class WithSharedUART(attach: SharedUART.Attach, gatePin: Int = 0) extends HarnessBinder({
  case (th: HasHarnessInstantiators, port: UARTPort, chipId: Int) if port.uartNo == 0 => {
    val s = SharedUART(th, chipId, attach)
    s.consoleTxd := port.io.txd
    port.io.rxd := s.rxd
  }
  case (th: HasHarnessInstantiators, port: UARTTSIPort, chipId: Int) => {
    val s = SharedUART(th, chipId, attach)
    s.tsiTxd := port.io.uart.txd
    port.io.uart.rxd := s.tsiRxd
  }
  case (th: HasHarnessInstantiators, port: GPIOPinsPort, chipId: Int) if port.gpioId == 0 => {
    require(gatePin < port.io.pins.size, s"TSI gate pin $gatePin, but GPIO 0 has ${port.io.pins.size} pins")
    val s = SharedUART(th, chipId, attach)
    port.io.pins.foreach { p =>
      p.i.ival := false.B
      p.i.po.foreach(_ := false.B)
    }
    val gate = port.io.pins(gatePin).o
    s.tsiBlock := gate.oe && gate.oval
  }
})

/** SPI-mode SD card model (see vsrc/SimSDCard.v). Image: +sdcard=<hex file>. */
class SimSDCard(memBytes: Int) extends BlackBox(Map("MEM_BYTES" -> chisel3.experimental.IntParam(memBytes)))
    with HasBlackBoxResource {
  val io = IO(new Bundle {
    val clock = Input(Clock())
    val reset = Input(Bool())
    val sck   = Input(Bool())
    val cs    = Input(Bool())
    val mosi  = Input(Bool())
    val miso  = Output(Bool())
  })
  addResource("/vsrc/SimSDCard.v")
}

/** Connect the first SPI controller to a [[SimSDCard]] (dq0 = MOSI, dq1 = MISO). */
class WithSimSDCard(memBytes: Int = 1 << 20) extends HarnessBinder({
  case (th: HasHarnessInstantiators, port: SPIPort, chipId: Int) => {
    val sd = Module(new SimSDCard(memBytes))
    sd.io.clock := th.harnessBinderClock
    sd.io.reset := th.harnessBinderReset.asBool
    sd.io.sck   := port.io.sck
    sd.io.cs    := port.io.cs(0)
    sd.io.mosi  := port.io.dq(0).o
    port.io.dq.foreach(_.i := false.B)
    port.io.dq(1).i := sd.io.miso
  }
})
