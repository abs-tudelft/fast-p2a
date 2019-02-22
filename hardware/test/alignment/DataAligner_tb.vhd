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

library std;
use std.textio.all;

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.std_logic_textio.all;

library work;
-- Fletcher utils for use of the log2ceil function
use work.Utils.all;

entity DataAligner_tb is
end DataAligner_tb;

architecture tb of DataAligner_tb is
  constant BUS_DATA_WIDTH       : natural := 512;
  constant NUM_CONSUMERS        : natural := 3;
  constant NUM_SHIFT_STAGES     : natural := 6;
  constant SHIFT_WIDTH          : natural := log2ceil(BUS_DATA_WIDTH/8);
  constant last_word_enc_width  : natural := 40;
  constant clk_period           : time    := 10 ns;
  constant init_misalignment    : natural := 15;

  signal clk                    : std_logic;
  signal reset                  : std_logic;
  signal in_valid               : std_logic;
  signal in_ready               : std_logic;
  signal in_data                : std_logic_vector(BUS_DATA_WIDTH-1 downto 0);
  signal out_valid              : std_logic_vector(NUM_CONSUMERS-1 downto 0);
  signal out_ready              : std_logic_vector(NUM_CONSUMERS-1 downto 0);
  signal out_data               : std_logic_vector(BUS_DATA_WIDTH-1 downto 0);
  signal bytes_consumed         : std_logic_vector(NUM_CONSUMERS*SHIFT_WIDTH-1 downto 0);
  signal bc_valid               : std_logic_vector(NUM_CONSUMERS-1 downto 0);
  signal bc_ready               : std_logic_vector(NUM_CONSUMERS-1 downto 0);
  signal prod_alignment         : std_logic_vector(SHIFT_WIDTH-1 downto 0);
  signal pa_valid               : std_logic;
  signal pa_ready               : std_logic;

begin
  dut: entity work.DataAligner
  generic map(
    BUS_DATA_WIDTH              => BUS_DATA_WIDTH,
    NUM_CONSUMERS               => NUM_CONSUMERS,
    NUM_SHIFT_STAGES            => NUM_SHIFT_STAGES
  )
  port map(
    clk                         => clk,
    reset                       => reset,
    in_valid                    => in_valid,
    in_ready                    => in_ready,
    in_data                     => in_data,
    out_valid                   => out_valid,
    out_ready                   => out_ready,
    out_data                    => out_data,
    bytes_consumed              => bytes_consumed,
    bc_valid                    => bc_valid,
    bc_ready                    => bc_ready,
    prod_alignment              => prod_alignment,
    pa_valid                    => pa_valid,
    pa_ready                    => pa_ready
  );

  upstream_p : process
    file input_data             : text;

    variable input_line         : line;
    variable bus_word           : std_logic_vector(BUS_DATA_WIDTH-1 downto 0);
  begin
    file_open(input_data, "./test/alignment/DataAligner_input.hex", read_mode);

    in_valid <= '0';
    in_data <= (others => '0');
    prod_alignment <= (others => '0');
    pa_valid <= '0';

    loop
      wait until rising_edge(clk);
      exit when reset = '0';
    end loop;

    pa_valid <= '1';
    prod_alignment <= std_logic_vector(to_unsigned(init_misalignment, prod_alignment'length));

    loop
      wait until rising_edge(clk);
      exit when pa_ready = '1';
    end loop;

    pa_valid <= '0';
    prod_alignment <= (others => '0');

    while not endfile(input_data) loop
      readline(input_data, input_line);
      hread(input_line, bus_word);

      in_valid <= '1';
      in_data <= bus_word;

      loop 
        wait until rising_edge(clk);
        exit when in_ready = '1';
      end loop;

      in_valid <= '0';
    end loop;

    report "All input data has been processed.";

    wait;
  end process;

  gen_consumers : for i in 0 to NUM_CONSUMERS-1 generate
    consumer_p : process
      file output_check         : text;

      variable check_line       : line;
      variable last_word_check  : std_logic_vector(last_word_enc_width-1 downto 0);
      variable remaining_data   : std_logic_vector(BUS_DATA_WIDTH-last_word_enc_width-1 downto 0);
      variable expected_output  : std_logic_vector(BUS_DATA_WIDTH-1 downto 0); 
    begin
      file_open(output_check, "./test/alignment/DataAligner_out" & integer'image(i) & ".hex", read_mode);

      out_ready(i) <= '0';
      bc_valid(i) <= '0';
      bytes_consumed(SHIFT_WIDTH*(i+1)-1 downto SHIFT_WIDTH*i) <= (others => '0');

      loop
        wait until rising_edge(clk);
        exit when reset = '0';
      end loop;

      while not endfile(output_check) loop
        readline(output_check, check_line);
        out_ready(i) <= '1';
  
        loop
          wait until rising_edge(clk);
          exit when out_valid(i) = '1';
        end loop;
  
        out_ready(i) <= '0';

        hread(check_line, last_word_check);

        if last_word_check(last_word_enc_width-1 downto last_word_enc_width-8) = x"00" then
          bc_valid(i) <= '1';
          bytes_consumed(SHIFT_WIDTH*(i+1)-1 downto SHIFT_WIDTH*i) <= std_logic_vector(resize(unsigned(last_word_check(last_word_enc_width-9 downto 0)), SHIFT_WIDTH));

          loop
            wait until rising_edge(clk);
            exit when bc_ready(i) = '1';
          end loop;

          bc_valid(i) <= '0';
        else
          hread(check_line, remaining_data);
          expected_output := last_word_check & remaining_data;

          assert out_data = expected_output
            report "Incorrect bus word received from DataAligner in consumer " & integer'image(i);
        end if;
      end loop;

      report "Consumer " & integer'image(i) & " has received all expected data.";

      wait;
    end process;
  end generate;

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
    wait for 20 ns;
    wait until rising_edge(clk);
    reset <= '0';
    wait;
  end process;

end architecture;