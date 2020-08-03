// Licensed to the Apache Software Foundation (ASF) under one
// or more contributor license agreements. See the NOTICE file
// distributed with this work for additional information
// regarding copyright ownership. The ASF licenses this file
// to you under the Apache License, Version 2.0 (the
// "License"); you may not use this file except in compliance
// with the License. You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied. See the License for the
// specific language governing permissions and limitations
// under the License.

/*
 * Author: Lars van Leeuwen
 * Code for running a Parquet to Arrow converter for 32 bit primitives on FPGA.
 *
 * Inputs:
 *  parquet_hw_input_file_path: file_path to hardware compatible Parquet file
 *  reference_parquet_file_path: file_path to Parquet file compatible with the standard Arrow library Parquet reading functions. 
 *    This file should contain the same values as the first file and is used for verifying the hardware output.
 *  num_val: How many values to read.
 */

#include <chrono>
#include <memory>
#include <array>
#include <iostream>
#include <fstream>
#include <iomanip>
#include <random>
#include <stdlib.h>
#include <unistd.h>

// Apache Arrow
#include <arrow/api.h>
#include <arrow/io/api.h>
#include <parquet/arrow/reader.h>
#include <parquet/arrow/writer.h>

// Fletcher
#include "fletcher/api.h"

#define REG_BASE 10

int min(int a, int b) {
	if (a < b) return a;
	else return b;
}

std::shared_ptr<arrow::RecordBatch> prepareRecordBatch(uint32_t num_strings, uint32_t num_chars) {
  std::shared_ptr<arrow::Buffer> values;
  std::shared_ptr<arrow::Buffer> offsets;

  arrow::Result<std::shared_ptr<arrow::Buffer>> bufResult = arrow::AllocateBuffer(num_chars);
  if (bufResult.ok()) {
	  values = bufResult.ValueOrDie();
  } else {
    throw std::runtime_error("Could not allocate values buffer.");
  }

  bufResult = arrow::AllocateBuffer(sizeof(int32_t)*(num_strings+1));
  if (bufResult.ok()) {
	offsets = bufResult.ValueOrDie();
  } else {
    throw std::runtime_error("Could not allocate offsets buffer.");
  }

  auto array = std::make_shared<arrow::StringArray>(num_strings, offsets, values);

//  This function no longer exists, not sure if passing meta data is necessary
//  auto schema_meta = metaMode(fletcher::Mode::WRITE);
  std::shared_ptr<arrow::Schema> schema = arrow::schema({arrow::field("str", arrow::utf8(), false)});//, schema_meta);

  auto rb = arrow::RecordBatch::Make(schema, num_strings, {array});

  return rb;
}


void setPtoaArguments(std::shared_ptr<fletcher::Platform> platform, uint32_t num_val,
		uint64_t max_size, da_t device_parquet_address) {
  dau_t mmio64_writer;

  platform->WriteMMIO(REG_BASE + 0, num_val);

  mmio64_writer.full = device_parquet_address;
  platform->WriteMMIO(REG_BASE + 1, mmio64_writer.lo);
  platform->WriteMMIO(REG_BASE + 2, mmio64_writer.hi);
  
  mmio64_writer.full = max_size;
  platform->WriteMMIO(REG_BASE + 3, mmio64_writer.lo);
  platform->WriteMMIO(REG_BASE + 4, mmio64_writer.hi);
  
  return;
}

//Use standard Arrow library functions to read Arrow array from Parquet file
//Only works for Parquet version 1 style files.
std::shared_ptr<arrow::ChunkedArray> readArray(std::string file_path) {
  std::shared_ptr<arrow::io::ReadableFile> infile;
  arrow::Status status;
  std::shared_ptr<arrow::ChunkedArray> array;

  arrow::Result<std::shared_ptr<arrow::io::ReadableFile>> result = arrow::io::ReadableFile::Open(file_path, arrow::default_memory_pool());
  if (result.ok()) {
    infile = result.ValueOrDie();
  } else {
	  printf("Error opening Parquet file: code %d, error message: %s\n",
			  result.status().code(), result.status().message().c_str());
	  exit(-1);
  }
  
  std::unique_ptr<parquet::arrow::FileReader> reader;
  status = parquet::arrow::OpenFile(infile, arrow::default_memory_pool(), &reader);
  if (!status.ok()) {
	  printf("Error creating parquet arrow reader: code %d, error message: %s\n",
			  status.code(), status.message().c_str());
	  exit(-1);
  }

  status = reader->ReadColumn(0, &array);
  if (!status.ok()) {
	  printf("Error reading column from parquet file: code %d, error message: %s\n",
			  status.code(), status.message().c_str());
	  exit(-1);
  }
  //printf("array->num_chunks() %d\n", array->num_chunks());
  //printf("array->length() %d\n", array->length());
  //for (int i = 0; i < array->length(); i++) {
  //	  printf("array[%02d]: [%s]\n", i, std::dynamic_pointer_cast<arrow::StringArray>(array->chunk(0))->GetString(i).c_str());
  //}

  return array;
}

int main(int argc, char **argv) {
  fletcher::Status status;
  std::shared_ptr<fletcher::Platform> platform;
  std::shared_ptr<fletcher::Context> context;

  fletcher::Timer t;

  char* hw_input_file_path;
  char* reference_parquet_file_path;
  uint32_t num_strings;
  uint32_t num_chars;
  uint64_t file_size;
  uint8_t* file_data;

  if (argc > 3) {
    hw_input_file_path = argv[1];
    reference_parquet_file_path = argv[2];
    num_strings = (uint32_t) std::strtoul(argv[3], nullptr, 10);

  } else {
    std::cerr << "Usage: str <parquet_hw_input_file_path> <reference_parquet_file_path> <num_strings>" << std::endl;
    return 1;
  }

  /*************************************************************
  * Parquet file reading
  *************************************************************/

  t.start();

  //Open parquet file
  std::ifstream parquet_file;
  parquet_file.open(hw_input_file_path, std::ifstream::binary);

  if(!parquet_file.is_open()) {
    std::cerr << "Error opening Parquet file" << std::endl;
    return 1;
  }

  //Reference array
  auto correct_array = std::dynamic_pointer_cast<arrow::StringArray>(readArray(
		  std::string(reference_parquet_file_path))->chunk(0));

  if (correct_array->length() > num_strings)
	  correct_array = std::dynamic_pointer_cast<arrow::StringArray>(
			  correct_array->Slice(0, num_strings));
  num_chars = correct_array->value_offset(num_strings);

  //Get filesize
  parquet_file.seekg (0, parquet_file.end);
  file_size = parquet_file.tellg();
  parquet_file.seekg (4, parquet_file.beg);

  //Read file data
  //file_data = (uint8_t*)std::malloc(file_size);
  posix_memalign((void**)&file_data, 4096, file_size - 4);
  parquet_file.read((char *)file_data, file_size - 4);
  unsigned int checksum = 0;
  for (int i = 0; i < file_size - 4; i++) {
    checksum += file_data[i];
  }
  printf("Parquet file checksum 0x%lu\n", checksum);


  /*************************************************************
  * FPGA RecordBatch preparation
  *************************************************************/

  t.start();
  auto arrow_rb_fpga = prepareRecordBatch(num_strings, num_chars);
  t.stop();
  std::cout << "Prepare FPGA RecordBatch         : "
            << t.seconds() << std::endl;
  auto result_array = std::dynamic_pointer_cast<arrow::StringArray>(arrow_rb_fpga->column(0));
  auto result_buffer_raw_offsets = result_array->value_offsets()->mutable_data();
  auto result_buffer_raw_values = result_array->value_data()->mutable_data();
  auto result_buffer_offsets_size = result_array->value_offsets()->size();
  auto result_buffer_values_size = result_array->value_data()->size();

  /*************************************************************
  * FPGA Initialization
  *************************************************************/

  // Create and initialize platform
  fletcher::Platform::Make(&platform).ewf("Could not create platform.");
  platform->Init();

  //Create context and kernel
  fletcher::Context::Make(&context, platform);
  fletcher::Kernel kernel(context);
  
  t.start();
  kernel.Reset();

  //Setup destination recordbatch on device
  context->QueueRecordBatch(arrow_rb_fpga);
  context->Enable();

  //Malloc parquet file on device
  da_t device_parquet_address;
  if (strcmp("oc-accel", platform->name().c_str()) == 0
		  || strcmp("snap", platform->name().c_str()) == 0) {
    printf("Platform [%s]: Skipping device buffer allocation and host to device copy.\n",
    		platform->name().c_str());
    // Set all the MMIO registers to their correct value
    setPtoaArguments(platform, num_strings, file_size, (da_t)(file_data));
  } else {
    platform->DeviceMalloc(&device_parquet_address, file_size);

    // Set all the MMIO registers to their correct value
    setPtoaArguments(platform, num_strings, file_size, device_parquet_address);
  }
  t.stop();
  std::cout << "FPGA Initialize                  : "
            << t.seconds() << std::endl;
    
  // Make sure the buffers are allocated
  memset(result_buffer_raw_offsets, 0, result_buffer_offsets_size);
  memset(result_buffer_raw_values, 0, result_buffer_values_size);

  /*************************************************************
  * FPGA host to device copy
  *************************************************************/

  t.start();
  platform->CopyHostToDevice(file_data, device_parquet_address, file_size);
  t.stop();
  std::cout << "FPGA host to device copy         : "
            << t.seconds() << std::endl;

  /*************************************************************
  * FPGA processing
  *************************************************************/

  t.start();
  kernel.Start();
  kernel.PollUntilDoneInterval(10);
  t.stop();
  std::cout << "FPGA processing time             : "
            << t.seconds() << std::endl;

  /*************************************************************
  * FPGA device to host copy
  *************************************************************/

  t.start();

  platform->CopyDeviceToHost(context->device_buffer(0).device_address,
  						 result_buffer_raw_offsets,
  						 sizeof(int32_t) * (num_strings+1));

  platform->CopyDeviceToHost(context->device_buffer(1).device_address,
  						 result_buffer_raw_values,
  						 num_chars);
  t.stop();

  size_t total_arrow_size = sizeof(int32_t) * (num_strings+1) + num_chars;

  std::cout << "FPGA device to host copy         : "
            << t.seconds() << std::endl;
  std::cout << "Arrow buffers total size         : "
            << total_arrow_size << std::endl;

  /*************************************************************
  * Check results
  *************************************************************/

  if (result_array->Equals(correct_array)) {
	  std::cout << "Test passed!" << std::endl;
  } else {
	  std::cout << "Test Failed!" << std::endl;
	/*  
	std::cout << "offsets arrays:" << std::endl;
	  std::cout << "correct array: ";
	  for (int i = 0; i < correct_array->value_offsets()->size(); i++) {
		  printf("%02x ", correct_array->value_offsets()->data()[i]);
	  }
	  std::cout << std::endl << "result array:  ";
	  for (int i = 0; i < correct_array->value_offsets()->size(); i++) {
		  printf("%02x ", result_array->value_offsets()->data()[i]);
	  }
	  std::cout << std::endl << "value arrays:" << std::endl;
	  std::cout << "correct array: ";
	  for (int i = 0; i < correct_array->value_data()->size(); i++) {
		  printf("%02x ", correct_array->value_data()->data()[i]);
	  }
	  std::cout << std::endl << "result array:  ";
	  for (int i = 0; i < correct_array->value_data()->size(); i++) {
		  printf("%02x ", result_array->value_data()->data()[i]);
	  }
	  std::cout << std::endl;
*/
  
  if(result_array->length() != num_strings){
    std::cout << "Number of results differ.\n";
  }
  int error_count = 0;
  for(int i=0; i<result_array->length(); i++) {
	if(result_array->GetString(i).compare(correct_array->GetString(i)) != 0) {
	  error_count++;
	}
  }

  if(error_count != 0) {
	std::cout << "Found " << error_count << " errors in the output Arrow array" << std::endl;
	std::cout << "First values: " << std::endl;

	for(int i=0; i<min(20, num_strings); i++) {
	  printf("result_array(%d): [%s], correct_array(%d): [%s]\n", i, result_array->GetString(i).c_str(), i, correct_array->GetString(i).c_str());
	}
  }
}
  std::free(file_data);

  return 0;

}

