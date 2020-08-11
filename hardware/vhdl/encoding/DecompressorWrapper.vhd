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
-- Fletcher utils for use of log2ceil function.
use work.UtilInt_pkg.all;
use work.Encoding.all;
use work.Snappy.all;

-- Todo: description

entity DecompressorWrapper is
  generic (
    -- Bus data width
    BUS_DATA_WIDTH              : natural;

    -- Compression
    COMPRESSION_CODEC           : string := "UNCOMPRESSED"
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
    newpage_in_data             : in std_logic_vector(3 * 32 - 1 downto 0); 

    -- Handshake signaling new page to output (ValuesDecoder)
    newpage_out_valid           : out std_logic;
    newpage_out_ready           : in  std_logic;
    newpage_out_data             : out std_logic_vector(3 * 32 - 1 downto 0); 

    --Data out stream to Fletcher ArrayWriter
    out_valid                   : out std_logic;
    out_ready                   : in  std_logic;
    out_data                    : out std_logic_vector(BUS_DATA_WIDTH-1 downto 0)
  );
end DecompressorWrapper;

architecture behv of DecompressorWrapper is

begin
  uncompressed_gen: if COMPRESSION_CODEC = "UNCOMPRESSED" generate
    in_ready          <= out_ready;
    out_valid         <= in_valid;
    out_data          <= in_data;
    newpage_out_valid <= newpage_in_valid;
    newpage_in_ready  <= newpage_out_ready;
    newpage_out_data   <= newpage_in_data;
  end generate;

  snappy_gen: if COMPRESSION_CODEC = "SNAPPY" generate
    snappy_inst: SnappyDecompressor
      generic map(
        BUS_DATA_WIDTH              => BUS_DATA_WIDTH
      )
      port map(
        clk                         => clk,
        reset                       => reset,
        in_valid                    => in_valid,
        in_ready                    => in_ready,
        in_data                     => in_data,
        newpage_in_valid            => newpage_in_valid,
        newpage_in_ready            => newpage_in_ready,
        newpage_in_data             => newpage_in_data,
        newpage_out_valid           => newpage_out_valid,
        newpage_out_ready           => newpage_out_ready,
        newpage_out_data            => newpage_out_data,
        out_valid                   => out_valid,
        out_ready                   => out_ready,
        out_data                    => out_data
      );
  end generate;
end architecture;
