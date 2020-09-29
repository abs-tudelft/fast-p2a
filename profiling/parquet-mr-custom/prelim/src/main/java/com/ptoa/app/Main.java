package com.ptoa.app;


import java.io.File;
import java.io.IOException;

import org.apache.hadoop.conf.Configuration;
import org.apache.hadoop.fs.Path;
import org.apache.parquet.ParquetReadOptions;
import org.apache.parquet.column.ParquetProperties.WriterVersion;
import org.apache.parquet.column.page.PageReadStore;
import org.apache.parquet.column.values.factory.ValuesWriterFactory;
import org.apache.parquet.example.data.Group;
import org.apache.parquet.example.data.simple.convert.GroupRecordConverter;
import org.apache.parquet.hadoop.ParquetFileReader;
import org.apache.parquet.hadoop.ParquetWriter;
import org.apache.parquet.hadoop.api.WriteSupport;
import org.apache.parquet.hadoop.example.GroupWriteSupport;
import org.apache.parquet.hadoop.metadata.CompressionCodecName;
import org.apache.parquet.hadoop.metadata.ParquetMetadata;
import org.apache.parquet.hadoop.util.HadoopInputFile;
import org.apache.parquet.io.ColumnIOFactory;
import org.apache.parquet.io.InputFile;
import org.apache.parquet.io.MessageColumnIO;
import org.apache.parquet.io.RecordReader;
import org.apache.parquet.schema.MessageType;

public class Main {
  private static final Configuration conf = new Configuration();

  public static class CustomBuilder extends ParquetWriter.Builder<Group, CustomBuilder> {

    private MessageType schema = null;

    private CustomBuilder(Path file) {
      super(file);
    }

    @Override
    protected CustomBuilder self() {
      return this;
    }

    @Override
    protected WriteSupport<Group> getWriteSupport(Configuration conf) {
      GroupWriteSupport.setSchema(schema, conf);
      return new GroupWriteSupport();
    }

    public CustomBuilder withSchema(MessageType prq_schema, Configuration conf) {
      this.schema = prq_schema;
      return self();
    }

    public CustomBuilder withValuesWriterFactory(ValuesWriterFactory factory) {
      this.encodingPropsBuilder.withValuesWriterFactory(factory);
      return self();
    }

  }

  public static void main(String[] args) throws IOException {
	if (args.length != 3 && args.length != 4) {
		System.out.printf("Arguments: <input parquet file> <output parquet file> <Page size> [delta]\n\n");
		System.exit(-1);
	}
	boolean deltaEncoding = false;
    InputFile in = HadoopInputFile.fromPath(new Path(args[0]), conf);
    Path destPath = new Path(args[1] + ".prq");
    Path destPath_snappy = new Path(args[1] + "_snappy.prq");

    ParquetFileReader reader = new ParquetFileReader(in, new ParquetReadOptions.Builder().build());
    ParquetMetadata readFooter = reader.getFooter();
    MessageType schema = readFooter.getFileMetaData().getSchema();
    PageReadStore pages = null;
    
    int pageSize = Integer.valueOf(args[2]);
    if (args.length >= 4 && args[3].contentEquals("delta")) {
    	deltaEncoding = true;
    }
    
    
    ValuesWriterFactory customV2Factory;
    if (deltaEncoding) {
    	customV2Factory = new CustomDeltaValuesWriterFactory();
    } else {
    	customV2Factory = new CustomPlainValuesWriterFactory();
    }

    File t = new File(destPath.toString());
    t.delete();
    File t_snappy = new File(destPath_snappy.toString());
    t_snappy.delete();

    //GroupWriteSupport.setSchema(schema, conf);
    //ParquetProperties.Builder encodingPropsBuilder = ParquetProperties.builder();
    //encodingPropsBuilder.withPageSize(10000000)
    //                    .withPageRowCountLimit(1000000000)
    //                    .withDictionaryEncoding(false)
    //                    .withValuesWriterFactory(customFactory)
    //                    .withWriterVersion(WriterVersion.PARQUET_2_0);
//
    //ParquetWriter<Group> writer = new ParquetWriter(
    //                                HadoopOutputFile.fromPath(destPath, conf),
    //                                ParquetFileWriter.Mode.OVERWRITE,
    //                                new GroupWriteSupport(),
    //                                CompressionCodecName.UNCOMPRESSED,
    //                                Integer.MAX_VALUE,
    //                                false,
    //                                conf,
    //                                ParquetWriter.MAX_PADDING_SIZE_DEFAULT,
    //                                encodingPropsBuilder.build());


    CustomBuilder writerBuilder = new CustomBuilder(destPath);
    writerBuilder.withSchema(schema, conf)
                 .withCompressionCodec(CompressionCodecName.UNCOMPRESSED)
                 .withRowGroupSize(Integer.MAX_VALUE)
                 .withPageSize(pageSize)
                 .withPageRowCountLimit(pageSize)
                 .withDictionaryEncoding(false)
                 .withValidation(false)
                 .withValuesWriterFactory(customV2Factory)
                 .withWriterVersion(WriterVersion.PARQUET_1_0);
    ParquetWriter<Group> writer = writerBuilder.build();
    CustomBuilder snappywriterBuilder = new CustomBuilder(destPath_snappy);
    snappywriterBuilder.withSchema(schema, conf)
    .withCompressionCodec(CompressionCodecName.SNAPPY)
    .withRowGroupSize(Integer.MAX_VALUE)
    .withPageSize(pageSize)
    .withPageRowCountLimit(pageSize)
    .withDictionaryEncoding(false)
    .withValidation(false)
    .withValuesWriterFactory(customV2Factory)
    .withWriterVersion(WriterVersion.PARQUET_1_0);
    ParquetWriter<Group> snappywriter = snappywriterBuilder.build();

    try {
      while (null != (pages = reader.readNextRowGroup())) {
        long rows = pages.getRowCount();
        System.out.println("Number of rows: " + pages.getRowCount());

        MessageColumnIO columnIO = new ColumnIOFactory().getColumnIO(schema);
        RecordReader<Group> recordReader = columnIO.getRecordReader(pages, new GroupRecordConverter(schema));
        for (int i = 0; i < rows; i++) {
          Group g = (Group) recordReader.read();
          writer.write(g);
          snappywriter.write(g);
        }
      }
    } finally {
      System.out.println("close the reader and writer");

      reader.close();
      writer.close();
      snappywriter.close();
    }
    /*
    try{
      PrintFooter.main(new String[] {destPath.toString()});
    } catch (Exception e){
      e.printStackTrace();
    }
    */
  }

}
