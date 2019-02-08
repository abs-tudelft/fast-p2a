-- Copyright 2018 Delft University of Technology
--
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

entity VarIntDecoder_tb is
end VarIntDecoder_tb;

architecture tb of VarIntDecoder_tb is
  constant INT_BIT_WIDTH         	   : natural := 32;
  constant ZIGZAG_ENCODED        	   : boolean := false;
  signal clk                         : std_logic;
  signal reset                       : std_logic;
  signal start                       : std_logic;
  signal in_data                     : std_logic_vector(7 downto 0);
  signal out_data                    : std_logic_vector(INT_BIT_WIDTH-1 downto 0);
  signal last_byte                   : std_logic;

  type state_t is (HEADER, FIELD);
    signal state, state_next : state_t;

  type mem is array (0 to 31) of std_logic_vector(7 downto 0);
  constant VarInt_ROM : mem := (
    0 => x"00", -- 0,
    1 => x"00",
    2 => x"00", -- 30,
    3 => x"1e",
    4 => x"00", -- 100,
    5 => x"64",
    6 => x"00", -- 127,
    7 => x"7f",
    8 => x"00", -- 128,
    9 => x"80",
    10 => x"01",
    11 => x"00", -- 201857,
    12 => x"81",
    13 => x"a9",
    14 => x"0c",
    15 => x"00", -- -50,
    16 => x"ce",
    17 => x"ff",
    18 => x"ff",
    19 => x"ff",
    20 => x"0f",
    21 => x"00", -- 18887,
    22 => x"c7",
    23 => x"93",
    24 => x"01",
    25 => x"00", -- -80000,
    26 => x"80",
    27 => x"8f",
    28 => x"fb",
    29 => x"ff",
    30 => x"0f",
    31 => x"00"
  );
begin
  dut: entity work.VarIntDecoder
  generic map(
    INT_BIT_WIDTH               <= INT_BIT_WIDTH,
    ZIGZAG_ENCODED              <= ZIGZAG_ENCODED
  )
  port map(
    clk                         <=clk,
    reset                       <=reset,
    start                       <=start,
    in_data                     <=in_data,
    out_data                    <=out_data,
    last_byte                   <=last_byte 
  );

  data_p : process
  begin
    state <= HEADER;
    loop
      wait until rising_edge(clk);
      exit when reset = '0';
    end loop;

    for i in 0 to VarInt_ROM'length loop
      in_data <= VarInt_ROM(i);
      if state = HEADER then
        start <= '1';
      else
        start <= '0';
      end if;

      wait until rising_edge(clk);
      state <= FIELD;
      if last_byte = '1' then
        state <= HEADER;
      end if;
    end loop;
  end process;

  clk_p : process
  begin
    clk <= '0';
    wait for clk_period/2;
    clk <= '1';
    wait for clk_period/2;
  end process;

  reset_p : process is
  begin
    reset <= '1';
    wait for 10 ns;
    wait until rising_edge(clk);
    reset <= '0';
    wait;
  end process;

end architecture;