-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.UtilInt_pkg.all;
use work.UtilMisc_pkg.all;
use work.Stream_pkg.all;
use work.Snappy.all;
use work.Ptoa.all;


-- This module is a wrapper for the vhsnunzip Snappy decompressor.
-- The vhsnunzip only supports 256 bit wide in and out data ports, so this wrapper does too.
-- If you want to use this decompressor with a narrower/wider bus you are going to need some StreamGearboxSerializers and StreamGearboxParallelizers.

entity SnappyDecompressor is
  generic (
    -- Bus data width
    BUS_DATA_WIDTH              : natural;
    DEC_DATA_WIDTH              : natural := 256;
    DECOMPRESSOR_COUNT          : natural := 6
  );
  port (
    -- Rising-edge sensitive clock.
    clk                         : in  std_logic;

    -- Active-high synchronous reset.
    reset                       : in  std_logic;

    -- Data in stream from PreDecBuffer
    in_valid                    : in  std_logic;
    in_ready                    : out std_logic;
    in_data                     : in  std_logic_vector(BUS_DATA_WIDTH-1 downto 0);

    -- Handshake signaling new page from input (PreDecBuffer)
    newpage_in_valid            : in  std_logic;
    newpage_in_ready            : out std_logic;
    newpage_in_data             : in  std_logic_vector(3 * 32 - 1 downto 0); 
        --page_num_values & compressed_size & uncompressed_size

    -- Handshake signaling new page to output (ValuesDecoder)
    newpage_out_valid           : out std_logic;
    newpage_out_ready           : in  std_logic;
    newpage_out_data            : out std_logic_vector(3 * 32 - 1 downto 0); 

    -- Compressed and uncompressed size of values in page (from MetadataInterpreter)
    --compressed_size             : in  std_logic_vector(31 downto 0);
    --uncompressed_size           : in  std_logic_vector(31 downto 0);

    --Data out stream to Fletcher ArrayWriter
    out_valid                   : out std_logic;
    out_ready                   : in  std_logic;
    out_data                    : out std_logic_vector(BUS_DATA_WIDTH-1 downto 0)
  );
end SnappyDecompressor;

architecture behv of SnappyDecompressor is

  type state_t is (IDLE, DECOMPRESSING, FLUSH_SERIALIZER);
  
  type reg_record is record
    state                : state_t;
    compression_length   : std_logic_vector(31 downto 0);
    decompression_length : std_logic_vector(31 downto 0);
    input_byte_counter   : unsigned(31 downto 0);
  end record;

  signal r : reg_record;
  signal d : reg_record;

  signal compressed_size        : std_logic_vector(31 downto 0);
  signal uncompressed_size      : std_logic_vector(31 downto 0);

  -- new page information fifo signals
  signal newpage_fifo_in_valid  : std_logic;
  signal newpage_fifo_in_ready  : std_logic;

  -- Data in stream
  signal in_data_s               : std_logic_vector(BUS_DATA_WIDTH-1 downto 0);

  -- Serializer to bytecounter and decompressor stream
  signal ser2dec_valid           : std_logic;
  signal ser2dec_ready           : std_logic;
  signal ser2dec_data            : std_logic_vector(DEC_DATA_WIDTH-1 downto 0);

  -- Decompressor in stream
  signal dec_in_valid            : std_logic;
  signal dec_in_ready            : std_logic;
  signal dec_in_data             : std_logic_vector(DEC_DATA_WIDTH-1 downto 0);
  signal dec_in_cnt              : std_logic_vector(4 downto 0);
  signal dec_in_last             : std_logic;

  -- Decompressor to parallelizer stream
  signal dec2par_valid           : std_logic;
  signal dec2par_ready           : std_logic;
  signal dec2par_data            : std_logic_vector(DEC_DATA_WIDTH-1 downto 0);
  signal dec2par_cnt             : std_logic_vector(4 downto 0);
  signal dec2par_last            : std_logic;

  signal out_data_rev            : std_logic_vector(BUS_DATA_WIDTH-1 downto 0);

begin
  assert DEC_DATA_WIDTH = 256
    report "Only 256 bit DEC_DATA_WIDTH is supported when using the Snappy decompressor" severity failure;

  in_data_s <= in_data;
  compressed_size   <= newpage_in_data(63 downto 32);
  uncompressed_size <= newpage_in_data(31 downto  0);

--TODO generate only if necessary
  serializer: StreamGearboxSerializer
    generic map(
      ELEMENT_WIDTH             => DEC_DATA_WIDTH,
      IN_COUNT_MAX              => BUS_DATA_WIDTH/DEC_DATA_WIDTH,
      IN_COUNT_WIDTH            => log2ceil(BUS_DATA_WIDTH/DEC_DATA_WIDTH)
    )
    port map(
      clk                       => clk,
      reset                     => reset,
      in_valid                  => in_valid,
      in_ready                  => in_ready,
      in_data                   => element_swap(in_data_s, DEC_DATA_WIDTH),
      out_valid                 => ser2dec_valid,
      out_ready                 => ser2dec_ready,
      out_data                  => ser2dec_data
    );

  -- Byteswap because vhsnunzip expects reversed order
  dec_in_data  <= element_swap(ser2dec_data, 8);

  inst: vhsnunzip
    generic map (
      COUNT       => DECOMPRESSOR_COUNT
    )
    port map (
      clk         => clk,
      reset       => reset,
      in_valid    => dec_in_valid,
      in_ready    => dec_in_ready,
      in_data     => dec_in_data,
      in_cnt      => dec_in_cnt,
      in_last     => dec_in_last,
      out_valid   => dec2par_valid,
      out_ready   => dec2par_ready,
      out_dvalid  => open,
      out_data    => dec2par_data,
      out_cnt     => dec2par_cnt,
      out_last    => dec2par_last
    );

--TODO generate only if necessary
-- Parallelize the data
    parallelizer: StreamGearboxParallelizer
      generic map (
        ELEMENT_WIDTH           => DEC_DATA_WIDTH,
        CTRL_WIDTH              => 0,
        IN_COUNT_MAX            => 1,
        IN_COUNT_WIDTH          => 1,
        OUT_COUNT_MAX           => BUS_DATA_WIDTH/DEC_DATA_WIDTH,
        OUT_COUNT_WIDTH         => log2ceil(BUS_DATA_WIDTH/DEC_DATA_WIDTH)
      )
      port map (
        clk                     => clk,
        reset                   => reset,

        in_valid                => dec2par_valid,
        in_ready                => dec2par_ready,
        in_data                 => element_swap(dec2par_data, 8),
        in_last                 => dec2par_last,

        out_valid               => out_valid,
        out_ready               => out_ready,
        out_data                => out_data_rev,
        out_last                => open
      );

    out_data <= element_swap(out_data_rev, DEC_DATA_WIDTH);

    page_fifo: StreamFIFO
        generic map(
            DEPTH_LOG2          => log2ceil(DECOMPRESSOR_COUNT),
            DATA_WIDTH          => 32 * 3 -- page_num_values, compressed_size, uncompressed_size
        )
        port map(
            in_clk              => clk,
            in_reset            => reset,
            in_valid            => newpage_fifo_in_valid,
            in_ready            => newpage_fifo_in_ready,
            in_data             => newpage_in_data,
            out_clk             => clk,
            out_reset           => reset,
            out_valid           => newpage_out_valid,
            out_ready           => newpage_out_ready,
            out_data            => newpage_out_data
        );

  -- Step 1 (IDLE): Register new page size to start the counter
  -- Step 2 (DECOMPRESSING): Stream data to decompressor, count bytes transferred, signal last (and count) if needed
  logic_p: process(newpage_in_valid, r, compressed_size, uncompressed_size, dec_in_ready, dec_in_valid, in_valid, ser2dec_valid, newpage_fifo_in_ready, newpage_in_valid)
    variable v : reg_record;
    variable bytes_left : std_logic_vector(31 downto 0) := (others => '0');
  begin
    v := r;
    dec_in_last  <= '0';
    dec_in_cnt <= (others => '0');

    -- Block new_page handshake
    newpage_in_ready     <= '0';
    newpage_fifo_in_valid <= '0';

    -- Block input data
    dec_in_valid  <= '0';
    ser2dec_ready <= '0';

    case r.state is
      when IDLE =>
        -- Unblock new page handshake
        newpage_in_ready      <= newpage_fifo_in_ready;
        newpage_fifo_in_valid <= newpage_in_valid;

        if newpage_in_valid = '1' then
          v.state                := DECOMPRESSING;
          v.compression_length   := compressed_size;
          v.decompression_length := uncompressed_size;
        end if;

      when DECOMPRESSING =>

        -- Unblock in data (conditionally)
        if r.input_byte_counter < unsigned(r.compression_length) then
          dec_in_valid  <= ser2dec_valid;
          ser2dec_ready <= dec_in_ready;
        end if;

        if dec_in_valid = '1' and dec_in_ready = '1' then
          v.input_byte_counter := r.input_byte_counter + DEC_DATA_WIDTH/8;
        end if;

        bytes_left := std_logic_vector(unsigned(unsigned(r.compression_length) - r.input_byte_counter));
        if unsigned(bytes_left) <= (DEC_DATA_WIDTH/8) then
          dec_in_last <= '1';
          dec_in_cnt <= bytes_left(4 downto 0);
          v.input_byte_counter := (others => '0');
          if ((unsigned(r.compression_length) mod (BUS_DATA_WIDTH/8)) > 0) and
             ((unsigned(r.compression_length) mod (BUS_DATA_WIDTH/8)) <= (DEC_DATA_WIDTH/8))  then
            v.state              := FLUSH_SERIALIZER;
          else
            v.state              := IDLE;
          end if;
        end if;
      when FLUSH_SERIALIZER => --there is an extra data word in the serializer, flush it
        ser2dec_ready <= '1';
        v.state                  := IDLE;
    end case;

    d <= v;
  end process;

  clk_p: process(clk)
  begin
    if rising_edge(clk) then
      if reset = '1' then
        r.state              <= IDLE;
        r.input_byte_counter <= (others => '0');
      else
        r <= d;
      end if;
    end if;
  end process;

end architecture;
