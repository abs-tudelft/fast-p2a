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
#include <vector>
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

// Fletcher
#include "fletcher/api.h"

#define REG_BASE 10

#define PRIM_WIDTH 32

std::shared_ptr<arrow::RecordBatch> prepareRecordBatch(uint32_t num_val) {
  std::shared_ptr<arrow::Buffer> values;

  arrow::Result<std::shared_ptr<arrow::Buffer>> bufResult = arrow::AllocateBuffer(sizeof(int32_t)*num_val);
  if (bufResult.ok()) {
	  values = bufResult.ValueOrDie();
  } else {
	throw std::runtime_error("Could not allocate values buffer.");
  }

  auto array = std::make_shared<arrow::Int32Array>(arrow::int32(), num_val, values);

  //  This function no longer exists, not sure if passing meta data is necessary
  //  auto schema_meta = metaMode(fletcher::Mode::WRITE);
    std::shared_ptr<arrow::Schema> schema = arrow::schema({arrow::field("int", arrow::int32(), false)});//, schema_meta);

  auto rb = arrow::RecordBatch::Make(schema, num_val, {array});

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

void checkMMIO(std::shared_ptr<fletcher::Platform> platform, uint32_t num_val, uint64_t max_size, da_t device_parquet_address, da_t device_arrow_address) {
  uint64_t value64;
  uint32_t value32;

  platform->ReadMMIO(2, &value32);

  std::cout << "MMIO num_val=" << value32 << ", should be " << num_val << std::endl;

}

//Use standard Arrow library functions to read Arrow array from Parquet file
//Only works for Parquet version 1 style files.
std::shared_ptr<arrow::ChunkedArray> readArray(std::string hw_input_file_path) {
  std::shared_ptr<arrow::io::ReadableFile> infile;
  arrow::Result<std::shared_ptr<arrow::io::ReadableFile>> result = arrow::io::ReadableFile::Open(hw_input_file_path);
  if (result.ok()) {
    infile = result.ValueOrDie();
  } else {
   printf("Error opening Parquet file: code %d, error message: %s\n",
 		  result.status().code(), result.status().message().c_str());
   exit(-1);
  }
  
  std::unique_ptr<parquet::arrow::FileReader> reader;
  parquet::arrow::OpenFile(infile, arrow::default_memory_pool(), &reader);

  std::shared_ptr<arrow::ChunkedArray> array;
  reader->ReadColumn(0, &array);

  return array;
}

int main(int argc, char **argv) {

  fletcher::Status status;
  std::shared_ptr<fletcher::Platform> platform;
  std::shared_ptr<fletcher::Context> context;

  fletcher::Timer t;

  char* hw_input_file_path;
  char* reference_parquet_file_path;
  uint32_t num_val;
  uint64_t file_size;
  uint8_t* file_data;

  if (argc > 3) {
    hw_input_file_path = argv[1];
    reference_parquet_file_path = argv[2];
    num_val = (uint32_t) std::strtoul(argv[3], nullptr, 10);

  } else {
    std::cerr << "Usage: prim32 <parquet_hw_input_file_path> <reference_parquet_file_path> <num_values>" << std::endl;
    return 1;
  }

  // Create a Fletcher platform object, attempting to autodetect the platform.
  status = fletcher::Platform::Make(&platform, false);

  if (!status.ok()) {
	std::cerr << "Could not create Fletcher platform." << std::endl;
	return -1;
  }

  /*************************************************************
  * Parquet file reading
  *************************************************************/

  //Open parquet file
  std::ifstream parquet_file;
  parquet_file.open(hw_input_file_path, std::ifstream::binary);

  if(!parquet_file.is_open()) {
    std::cerr << "Error opening Parquet file" << std::endl;
    return 1;
  }

  //Get filesize
  parquet_file.seekg (0, parquet_file.end);
  file_size = parquet_file.tellg();
  parquet_file.seekg (0, parquet_file.beg);

  //Read file data
  //file_data = (uint8_t*)std::malloc(file_size);
  posix_memalign((void**)&file_data, 4096, file_size);
  parquet_file.read((char *)file_data, file_size);


  /*************************************************************
  * FPGA RecordBatch preparation
  *************************************************************/

  t.start();
  auto arrow_rb_fpga = prepareRecordBatch(num_val);
  t.stop();
  std::cout << "Prepare FPGA RecordBatch         : "
            << t.seconds() << std::endl;

  /*************************************************************
  * FPGA Initilialization
  *************************************************************/

  t.start();
  // Create and initialize platform
  fletcher::Platform::Make(&platform).ewf("Could not create platform.");
  platform->Init();

  //Create context
  fletcher::Context::Make(&context, platform);

  fletcher::Kernel kernel(context);

  //Setup destination recordbatch on device
  context->QueueRecordBatch(arrow_rb_fpga);
  context->Enable();

  //Malloc parquet file on device
  if (strcmp("oc-accel", platform->name().c_str()) == 0
		  || strcmp("snap", platform->name().c_str()) == 0) {
    printf("Platform [%s]: Skipping device buffer allocation and host to device copy.\n",
    		platform->name().c_str());
    // Set all the MMIO registers to their correct value
    // Add 4 to device_parquet_address to skip magic number
    setPtoaArguments(platform, num_val, file_size, (da_t)(file_data+4));
    t.stop();
  } else {
    da_t device_parquet_address;
    platform->DeviceMalloc(&device_parquet_address, file_size);

    // Set all the MMIO registers to their correct value
    // Add 4 to device_parquet_address to skip magic number
    setPtoaArguments(platform, num_val, file_size, device_parquet_address+4);
    t.stop();
    std::cout << "FPGA Initialize                  : "
              << t.seconds() << std::endl;

    checkMMIO(platform, num_val, file_size, device_parquet_address,
  		  context->device_buffer(0).device_address);

    /*************************************************************
    * FPGA host to device copy
    *************************************************************/

    t.start();
    platform->CopyHostToDevice(file_data, device_parquet_address, file_size);
    t.stop();
    std::cout << "FPGA host to device copy         : "
              << t.seconds() << std::endl;
  }

  /*************************************************************
  * FPGA processing
  *************************************************************/

  t.start();
  kernel.Reset();
  kernel.Start();
  kernel.PollUntilDoneInterval(10);
  t.stop();
  std::cout << "FPGA processing time             : "
            << t.seconds() << std::endl;

  /*************************************************************
  * FPGA device to host copy
  *************************************************************/

  t.start();
  auto result_array = std::dynamic_pointer_cast<arrow::Int32Array>(arrow_rb_fpga->column(0));
  auto result_buffer_raw_data = result_array->values()->mutable_data();
  platform->CopyDeviceToHost(context->device_buffer(0).device_address,
                             result_buffer_raw_data,
                             sizeof(int32_t) * (num_val));
  t.stop();

  size_t total_arrow_size = sizeof(int32_t) * num_val;
  
  std::cout << "FPGA device to host copy         : "
            << t.seconds() << std::endl;
  std::cout << "Arrow buffers total size         : "
            << total_arrow_size << std::endl;

  /*************************************************************
  * Check results
  *************************************************************/

  auto correct_array = std::dynamic_pointer_cast<arrow::Int32Array>(readArray(
		  std::string(reference_parquet_file_path))->chunk(0));
  int error_count = 0;
  for(int i=0; i<result_array->length(); i++) {
    if(result_array->Value(i) != correct_array->Value(i)) {
      error_count++;
    }
    if(i<20) {
      std::cout << result_array->Value(i) << " " << correct_array->Value(i) << std::endl;
    }

  }

  if(result_array->length() != num_val){
    error_count++;
  }

  if(error_count == 0) {
    std::cout << "Test passed!" << std::endl;
  } else {
    std::cout << "Test failed. Found " << error_count << " errors in the output Arrow array" << std::endl;
  }

  std::free(file_data);

  return 0;

}
