package chipyard

import java.io.File

import scala.sys.process._

import org.chipsalliance.cde.config.{Config}
import freechips.rocketchip.devices.tilelink.{BootROMLocated, BootROMParams}
import freechips.rocketchip.subsystem.{InSubsystem, PeripheryBusKey}
import freechips.rocketchip.util.{SystemFileName}

import sifive.blocks.devices.uart.{PeripheryUARTKey, UARTParams}
import sifive.blocks.devices.spi.{PeripherySPIKey, SPIParams}
import sifive.blocks.devices.gpio.{PeripheryGPIOKey, GPIOParams}

// ---------------------------------------------------------------------------
// Dual boot (bare-metal over UART-TSI / Linux from SD) on one bitstream.
//
// Building blocks shared by the VCU118 board config
// (fpga/src/main/scala/vcu118/Configs.scala: WithVCU118DualBootTweaks) and
// the simulation config below. Harness side: harness/DualBootHarnessBinders.
// ---------------------------------------------------------------------------

/** Boot ROM = sdboot built with -DDUALBOOT (fpga/src/main/resources/vcu118/sdboot).
  *
  * The ROM waits for the host: MSIP (uart_tsi loaded a program) -> bare-metal,
  * mailbox magic (uart_tsi_dual.py --boot-linux) -> SD copy and Linux.
  * Each parameter set builds into its own directory, so neither the default
  * sdboot ROM (build/) nor another dual-boot variant is overwritten.
  *
  * Elaboration must run from the chipyard root, as for the other VCU118 configs.
  *
  * @param payloadSizeB  bytes copied from the SD card (sdboot default 30 MiB)
  * @param spiClkKHz     SPI SCK for the payload copy (CMD18)
  * @param spiInitClkKHz SPI SCK for card initialization (CMD0..CMD16); the SD
  *                      spec allows 100-400 kHz there
  */
class WithDualBootROM(
  payloadSizeB: BigInt = 30 << 20,
  spiClkKHz: Int = 25000,
  spiInitClkKHz: Int = 300,
  sdbootDir: String = "fpga/src/main/resources/vcu118/sdboot"
) extends Config((site, here, up) => {
  case BootROMLocated(InSubsystem) => {
    val pbusMHz = (site(PeripheryBusKey).dtsFrequency.get / (1000 * 1000)).toLong
    val buildDir = s"${sdbootDir}/build-dualboot-${pbusMHz}MHz-${payloadSizeB}B-init${spiInitClkKHz}kHz-${spiClkKHz}kHz"
    val defs = s"-DDUALBOOT -DPAYLOAD_SIZE_B=${payloadSizeB} -DSPI_CLK=${spiClkKHz} -DSPI_INIT_CLK=${spiInitClkKHz}"
    val make = Seq("make", "-C", sdbootDir,
      s"BUILD_DIR=${new File(buildDir).getAbsolutePath}", s"PBUS_CLK=${pbusMHz}", s"BOOT_DEFS=${defs}", "bin")
    require(make.! == 0, s"Failed to build the dual-boot ROM: ${make.mkString(" ")}")
    Seq(BootROMParams(hang = 0x10000, contentFileName = SystemFileName(s"./${buildDir}/sdboot.bin")))
  }
})

/** Peripheral addresses hard-coded in sdboot's include/platform.h.
  * GPIO is one pin: GPIO[0] closes the UART-TSI gate.
  */
class WithVCU118PeripheralMap(consoleBaud: BigInt = 921600) extends Config((site, here, up) => {
  case PeripheryUARTKey => List(UARTParams(address = BigInt(0x64000000L), initBaudRate = consoleBaud))
  case PeripherySPIKey  => List(SPIParams(rAddress = BigInt(0x64001000L)))
  case PeripheryGPIOKey => List(GPIOParams(address = BigInt(0x64002000L), width = 1))
})

/** Simulation twin of the VCU118 dual-boot SoC.
  *
  * Same parts as the board config (shared UART + gate, GPIO pin, dual-boot
  * ROM, peripheral map); the line ends in a pty and the SD card is SimSDCard.
  * Faster than the board so Verilator gets through the SD path in minutes:
  * 100 MHz buses, 3.125 Mbaud (div 32; a pty has no baud anyway), an 8 KiB
  * payload. SCK: 300 kHz for init as on the board (SPI_INIT_DIV 165), 5 MHz
  * for the copy (SPI_DIV 9, well inside SimSDCard's oversampling).
  *
  *   simulator-chipyard.harness-DualBootRocketConfig +sdcard=<hex> ... none
  */
class DualBootRocketConfig extends Config(
  new chipyard.harness.WithSharedUART(chipyard.harness.SharedUART.simPty(3125000)) ++
  new chipyard.harness.WithSimSDCard ++
  new chipyard.harness.WithSerialTLTiedOff ++
  new chipyard.iobinders.WithGPIOPunchthrough ++
  new testchipip.tsi.WithUARTTSIClient(initBaudRate = BigInt(3125000)) ++
  new chipyard.WithDualBootROM(payloadSizeB = 0x2000, spiClkKHz = 5000, spiInitClkKHz = 300) ++
  new chipyard.WithVCU118PeripheralMap(consoleBaud = 3125000) ++
  new chipyard.config.WithUniformBusFrequencies(100) ++
  new freechips.rocketchip.rocket.WithNHugeCores(1) ++
  new chipyard.config.AbstractConfig)
