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
use ieee.math_real.all;

library work;
use work.Utils.all;
use work.Ptoa.all;

package Delta is

  component BlockHeaderReader is
    generic (
      DEC_DATA_WIDTH              : natural;
      BLOCK_SIZE                  : natural;
      MINIBLOCKS_IN_BLOCK         : natural;
      BYTES_IN_BLOCK_WIDTH        : natural := 16;
      FIFO_DEPTH                  : natural;
      PRIM_WIDTH                  : natural
    );
    port (
      clk                         : in  std_logic;
      reset                       : in  std_logic;
      page_done                   : out std_logic;
      in_valid                    : in  std_logic;
      in_ready                    : out std_logic;
      in_data                     : in  std_logic_vector(DEC_DATA_WIDTH-1 downto 0);
      page_num_values             : in  std_logic_vector(31 downto 0);
      md_valid                    : out std_logic;
      md_ready                    : in  std_logic;
      md_data                     : out std_logic_vector(PRIM_WIDTH-1 downto 0);
      bw_valid                    : out std_logic;
      bw_ready                    : in  std_logic;
      bw_data                     : out std_logic_vector(7 downto 0);
      bl_valid                    : out std_logic;
      bl_ready                    : in  std_logic;
      bl_data                     : out std_logic_vector(log2floor(max_varint_bytes(PRIM_WIDTH)+MINIBLOCKS_IN_BLOCK) downto 0);
      bc_valid                    : out std_logic;
      bc_ready                    : in  std_logic;
      bc_data                     : out std_logic_vector(BYTES_IN_BLOCK_WIDTH-1 downto 0)
    );
  end component;

  component BlockShiftControl is
    generic (
      DEC_DATA_WIDTH              : natural;
      BLOCK_SIZE                  : natural;
      MINIBLOCKS_IN_BLOCK         : natural;
      MAX_DELTAS_PER_CYCLE        : natural;
      PRIM_WIDTH                  : natural;
      COUNT_WIDTH                 : natural;
      WIDTH_WIDTH                 : natural;
      AMOUNT_WIDTH                : natural
    );
    port (
      clk                         : in  std_logic;
      reset                       : in  std_logic;
      page_done                   : out std_logic;
      in_valid                    : in  std_logic;
      in_ready                    : out std_logic;
      in_data                     : in  std_logic_vector(DEC_DATA_WIDTH-1 downto 0);
      page_num_values             : in  std_logic_vector(31 downto 0);
      bw_valid                    : in  std_logic;
      bw_ready                    : out std_logic;
      bw_data                     : in  std_logic_vector(7 downto 0);
      bl_valid                    : in  std_logic;
      bl_ready                    : out std_logic;
      bl_data                     : in  std_logic_vector(log2floor(max_varint_bytes(PRIM_WIDTH)+MINIBLOCKS_IN_BLOCK) downto 0);
      out_valid                   : out std_logic;
      out_ready                   : in  std_logic;
      out_data                    : out std_logic_vector(2*DEC_DATA_WIDTH-1 downto 0);
      out_amount                  : out std_logic_vector(AMOUNT_WIDTH-1 downto 0);
      out_width                   : out std_logic_vector(WIDTH_WIDTH-1 downto 0);
      out_count                   : out std_logic_vector(COUNT_WIDTH-1 downto 0)
    );
  end component;

  -----------------------------------------------------------------------------
  -- Helper functions
  -----------------------------------------------------------------------------
  type count_lut_64_t is array (0 to 64) of natural range 1 to 32;
  type count_lut_32_t is array (0 to 32) of natural range 1 to 32;

  type shift_lut_64_t is array (0 to 64) of natural;
  type shift_lut_32_t is array (0 to 32) of natural;

  -- These functions initialize the lut containing the amount of values to unpack per cycle for every bit packing width.
  -- For every bit width this amount needs to divide 32 (always a divisor of the amount of values in a miniblock) 
  -- without a remainder to ensure that after an x amount of cycles the entire miniblock has been unpacked without
  -- taking bits from the next miniblock.
  function init_count_lut_64(MAX_DELTAS_PER_CYCLE : natural; DEC_DATA_WIDTH : natural) return count_lut_64_t;
  function init_count_lut_32(MAX_DELTAS_PER_CYCLE : natural; DEC_DATA_WIDTH : natural) return count_lut_32_t;

  -- Initialize the luts containing the amount of bits to shift (count*width)
  function init_shift_lut_64(MAX_DELTAS_PER_CYCLE : natural; DEC_DATA_WIDTH : natural) return shift_lut_64_t;
  function init_shift_lut_32(MAX_DELTAS_PER_CYCLE : natural; DEC_DATA_WIDTH : natural) return shift_lut_32_t;

  -- Returns either a rounded down to the nearest power of 2 or 32 , whichever is smaller.
  function round_down_pow2(a : natural) return natural;

  -- Returns the amount of values unpacked per cycle for a certain width based on MAX_DELTAS and DATA_WIDTH
  function unpacking_count(width : natural; MAX_DELTAS_PER_CYCLE : natural; DEC_DATA_WIDTH : natural) return natural;
end Delta;

package body Delta is

  function round_down_pow2(a : natural) return natural is
  begin
    return work.Utils.MIN(2 ** log2floor(a), 32);
  end function;

  function unpacking_count(width : natural; MAX_DELTAS_PER_CYCLE : natural; DEC_DATA_WIDTH : natural) return natural is
  begin
    if width = 0 then
      return MAX_DELTAS_PER_CYCLE;
    else
      return work.Utils.MIN(MAX_DELTAS_PER_CYCLE, round_down_pow2(natural(FLOOR(real(DEC_DATA_WIDTH)/real(width)))));
    end if;
  end function;

  function init_count_lut_32(MAX_DELTAS_PER_CYCLE : natural; DEC_DATA_WIDTH : natural) return count_lut_32_t is
    variable result : count_lut_32_t;
  begin
    for i in 0 to 32 loop
      result(i) := unpacking_count(i, MAX_DELTAS_PER_CYCLE, DEC_DATA_WIDTH);
    end loop;

    return result;
  end function;

  function init_count_lut_64(MAX_DELTAS_PER_CYCLE : natural; DEC_DATA_WIDTH : natural) return count_lut_64_t is
    variable result : count_lut_64_t;
  begin
    for i in 0 to 64 loop
      result(i) := unpacking_count(i, MAX_DELTAS_PER_CYCLE, DEC_DATA_WIDTH);
    end loop;

    return result;
  end function;

  function init_shift_lut_32(MAX_DELTAS_PER_CYCLE : natural; DEC_DATA_WIDTH : natural) return shift_lut_32_t is
    variable result : shift_lut_32_t;
  begin
    for i in 0 to 32 loop
      result(i) := unpacking_count(i, MAX_DELTAS_PER_CYCLE, DEC_DATA_WIDTH) * i;
    end loop;

    return result;
  end function;

  function init_shift_lut_64(MAX_DELTAS_PER_CYCLE : natural; DEC_DATA_WIDTH : natural) return shift_lut_64_t is
    variable result : shift_lut_64_t;
  begin
    for i in 0 to 64 loop
      result(i) := unpacking_count(i, MAX_DELTAS_PER_CYCLE, DEC_DATA_WIDTH) * i;
    end loop;

    return result;
  end function;


end Delta;