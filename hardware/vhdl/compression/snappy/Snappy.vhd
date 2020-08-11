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
use ieee.std_logic_misc.all;
use ieee.numeric_std.all;

package Snappy is

  component SnappyDecompressor is
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
            --page_num_values & compressed_size & decompressed_size

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
  end component;

component vhsnunzip is
  generic (
    COUNT       : positive := 8;
    B2U_MUL     : natural := 21;
    B2U_DIV     : positive := 10

  );
  port (
    clk         : in  std_logic;
    reset       : in  std_logic;

    in_valid    : in  std_logic;
    in_ready    : out std_logic;
    in_data     : in  std_logic_vector(255 downto 0);
    in_cnt      : in  std_logic_vector(4 downto 0);
    in_last     : in  std_logic;

    out_valid   : out std_logic;
    out_ready   : in  std_logic;
    out_dvalid  : out std_logic;
    out_data    : out std_logic_vector(255 downto 0);
    out_cnt     : out std_logic_vector(4 downto 0);
    out_last    : out std_logic

  );
end component;

end Snappy;
