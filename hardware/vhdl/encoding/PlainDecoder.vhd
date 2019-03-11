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
use work.Utils.all;

-- Todo: description

entity PlainDecoder is
  generic (
    -- Bus data width
    BUS_DATA_WIDTH              : natural;

    -- Bit width of a single primitive value
    PRIM_WIDTH                  : natural
  );
  port (
    -- Rising-edge sensitive clock.
    clk                         : in  std_logic;

    -- Active-high synchronous reset.
    reset                       : in  std_logic;

    ctrl_done                   : out std_logic;

    -- Data in stream from Decompressor
    in_valid                    : in  std_logic;
    in_ready                    : out std_logic;
    in_data                     : in  std_logic_vector(BUS_DATA_WIDTH-1 downto 0);

    -- Handshake signaling start of new page
    new_page_valid              : in  std_logic;
    new_page_ready              : out std_logic;

    -- Total number of requested values (from host)
    total_num_values            : in  std_logic_vector(31 downto 0);

    -- Number of values in the page (from MetadataInterpreter)
    page_num_values             : in  std_logic_vector(31 downto 0);

    --Data out stream to Fletcher ColumnWriter
    out_valid                   : out std_logic;
    out_ready                   : in  std_logic;
    out_last                    : out std_logic;
    out_dvalid                  : out std_logic := '1';
    out_data                    : out std_logic_vector(BUS_DATA_WIDTH-1 downto 0)
  );
end PlainDecoder;

architecture behv of PlainDecoder is
  -- The amount of values transferred to the ColumnWriter every cycle
  constant ELEMENTS_PER_CYCLE : natural := BUS_DATA_WIDTH/PRIM_WIDTH;

  type state_t is (IDLE, DECODING);

  type reg_record is record 
    state             : state_t;
    page_val_counter  : unsigned(31 downto 0);
    total_val_counter : unsigned(31 downto 0);
    m_page_num_values : unsigned(31 downto 0);
    val_reg_count     : integer range (0 to ELEMENTS_PER_CYCLE-1);
    val_reg           : std_logic_vector((ELEMENTS_PER_CYCLE-1)*PRIM_WIDTH-1 downto 0);
  end record;

  signal r : reg_record;
  signal d : reg_record;

  -- Signal with in_data in correct byte order
  signal s_in_data : std_logic_vector(BUS_DATA_WIDTH-1 downto 0);
begin

  s_in_data <= endian_swap(in_data);

  logic_p: process(r)
    constant val_misalignment     : unsigned(log2ceil(ELEMENTS_PER_CYCLE)-1 downto 0) := r.m_page_num_values(log2ceil(ELEMENTS_PER_CYCLE)-1 downto 0);

    variable v                    : reg_record;
    variable page_val_counter_inc : unsigned(31 downto 0);
    variable new_val_reg_count    : integer range (0 to (ELEMENTS_PER_CYCLE-1)*2);
  begin
    v := r;

    new_page_ready <= '0';
    in_ready <= '0';
    out_valid <= '0';
    out_data <= (others => '0');

    page_val_counter_inc := r.page_val_counter + ELEMENTS_PER_CYCLE;

    case r.state is
      when IDLE =>
        new_page_ready <= '1';
        if new_page_valid = '1' then
          v.state             := DECODING;
          v.m_page_num_values := unsigned(page_num_values);
          v.page_val_counter  := (others => '0');
        end if;

      when IN_PAGE =>
        if page_val_counter_inc + r.total_val_counter > total_num_values then
          v.state := PAGE_END;
        else
          in_ready <= out_ready;
          out_valid <= in_valid;
          if in_valid = '1' and out_ready = '1' then
            if r.val_reg_count = 0 then
              out_data <= in_data;
            else
              out_data <= in_data(PRIM_WIDTH*(ELEMENTS_PER_CYCLE-r.val_reg_count)-1 downto 0) & r.val_reg(PRIM_WIDTH*r.val_reg_count-1 downto 0);
              v.val_reg := in_data(BUS_DATA_WIDTH-1 downto PRIM_WIDTH*(ELEMENTS_PER_CYCLE-r.val_reg_count));
            end if;
  
            if page_val_counter_inc + r.total_val_counter > total_num_values then
              v.state := DONE;
            else
              v.page_val_counter := page_val_counter_inc;
            end if;
          end if;
        end if;

      when PAGE_END =>
        new_val_reg_count := r.val_reg_count + val_misalignment;

        if new_val_reg_count > (ELEMENTS_PER_CYCLE-1) then
          in_ready <= out_ready;
          out_valid <= in_valid;
          if in_valid = '1' and out_ready = '1' then
            v.val_reg_count := unsigned(new_val_reg_count(val_misalignment'length-1 downto 0))
            out_data <= in_data(PRIM_WIDTH*(ELEMENTS_PER_CYCLE-r.val_reg_count)-1 downto 0) & r.val_reg(PRIM_WIDTH*r.val_reg_count-1 downto 0);
            v.val_reg := in_data(BUS_DATA_WIDTH-1 downto PRIM_WIDTH*(ELEMENTS_PER_CYCLE-v.val_reg_count));
            -- Todo: finish this
          end if;
          -- Todo: finish this
        end if;


      when DONE =>


    end case;

    d <= v;
  end process;

  clk_p: process (clk)
  begin
    if rising_edge(clk) then
      if reset = '1' then
        r.state             <= IDLE;
        r.page_val_counter  <= (others => '0');
        r.total_val_counter <= (others => '0');
        val_reg_count       <= 0;
      else
        r <= d;
      end if;
    end if;
  end process;

end architecture;