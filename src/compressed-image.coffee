
class CompressedImage extends BinaryTable
  @include ImageUtils
  @extend Decompress
  
  
  # Predefined random number generator from http://arxiv.org/pdf/1201.1336v1.pdf
  # This is the same method used by fpack when dithering images during compression.
  @randomGenerator: ->
    a = 16807
    m = 2147483647
    seed = 1
    
    random = new Float32Array(10000)
    
    for i in [0..9999]
      temp = a * seed
      seed = temp - m * parseInt(temp / m)
      random[i] = seed / m
      
    return random
  
  # Store the random look up table on the class.
  @randomSequence = @randomGenerator()
  
  
  constructor: (header, view, offset) ->
    super
    
    # Get compression values
    @zcmptype = header.get("ZCMPTYPE")
    @zbitpix  = header.get("ZBITPIX")
    @znaxis   = header.get("ZNAXIS")
    @zblank   = header.get("ZBLANK")
    @blank    = header.get("BLANK")
    @zdither  = header.get('ZDITHER0') or 0
    
    @ztile = []
    for i in [1..@znaxis]
      ztile = if header.contains("ZTILE#{i}") then header.get("ZTILE#{i}") else if i is 1 then header.get("ZNAXIS1") else 1
      @ztile.push ztile
    
    @width  = header.get("ZNAXIS1")
    @height = header.get("ZNAXIS2") or 1
    
    # Storage for compression algorithm parameters
    @algorithmParameters = {}
    
    # Set default parameters
    if @zcmptype is 'RICE_1'
      @algorithmParameters["BLOCKSIZE"] = 32
      @algorithmParameters["BYTEPIX"] = 4
    
    # Get compression algorithm parameters (override defaults when keys present)
    i = 1
    loop
      key = "ZNAME#{i}"
      break unless header.contains(key)
      
      value = "ZVAL#{i}"
      @algorithmParameters[ header.get(key) ] = header.get(value)
      
      i += 1
    
    @zmaskcmp = header.get("ZMASKCMP")
    @zquantiz = header.get("ZQUANTIZ") or "LINEAR_SCALING"
    
    @bzero  = header.get("BZERO") or 0
    @bscale = header.get("BSCALE") or 1
    
    # Define the internal _getRow function
    hasBlanks = @zblank? or @blank? or @columns.indexOf("ZBLANK") > -1
    @_getRows = if hasBlanks then @_getRowsHasBlanks else @_getRowsNoBlanks
    
  # TODO: Test this function.  Need example file with blanks.
  # TODO: Implement subtractive dithering
  _getRowsHasBlanks: (buffer) ->
    [data, blank, scale, zero] = @getTableRow()
    # Cache frequently accessed variables
    random = @constructor.randomSequence
    ditherOffset = @ditherOffset
    offset = @rowsRead * @width
    
    for value, index in data
      i = offset + index
      r = random[ditherOffset]
      arr[i] = if value is blank then NaN else (value - r + 0.5) * scale + zero
      ditherOffset = (ditherOffset + 1) % 10000
    @rowsRead += 1
    
  # _getRowsNoBlanks: (buffer) ->
  #   [data, blank, scale, zero] = @getTableRow()
  #   
  #   width = @width
  #   offset = @rowsRead * width
  #   randomSeq = @randomSeq
  #   zdither = @zdither
  #   
  #   for value, index in data
  #     i = offset + index
  #     
  #     # Get tile number (usually tiles are row-wise)
  #     # TODO: Optimize int casting
  #     # nTile = parseInt(index / width)
  #     # r = @getRandom(nTile)
  #     
  #     r = randomSeq[zdither]
  #     
  #     # Unquantize the pixel intensity
  #     arr[i] = (value - r + 0.5) * scale + zero
  #     zdither = (zdither + 1) % 10000
  #   
  #   @rowsRead += 1
  
  _getRowsNoBlanks: (buffer) ->
    
    # TODO: Duplicate code in binary table method. Abstract this line, input as argument to function.
    nRows = buffer.byteLength / @rowByteSize
    
    # Set up view and offset
    view = new DataView(buffer)
    offset = 0
    
    # Set up storage for frame
    arr = new Float32Array(@width * @height)
    
    # Read each row (tile)
    while nRows--
      
      # Storage for current row
      row = {}
      
      for accessor, index in @accessors
        
        # Read value from each column in current row
        [value, offset] = accessor(view, offset)
        
        row[ @columns[index] ] = value
        
        # Get array from column with returned values
        # TODO: Check that data is returned correctly when UNCOMPRESSED_DATA or GZIP_COMPRESSED_DATA present
        data  = row['COMPRESSED_DATA'] or row['UNCOMPRESSED_DATA'] or row['GZIP_COMPRESSED_DATA']
        blank = row['ZBLANK'] or @zblank
        scale = row['ZSCALE'] or @bscale
        zero  = row['ZZERO'] or @bzero
        
      # Set initial seeds using tile number and ZDITHER0 (assuming row by row tiling)
      nTile = @height - nRows
      seed0 = nTile + @zdither - 1
      seed1 = (seed0 - 1) % 10000
      
      # Set initial index in random sequence
      rIndex = parseInt(@constructor.randomSequence[seed1] * 500)
      
      for value, index in data
        
        # Get the pixel index
        i = (nTile - 1) * @width + index
        
        if value is -2147483647
          arr[i] = NaN
        else if value is -2147483646
          arr[i] = 0
        else
          r = @constructor.randomSequence[rIndex]
          arr[i] = (value - r + 0.5) * scale + zero
        
        # Update the random index
        rIndex += 1
        if rIndex is 10000
          seed1 = (seed1 + 1) % 10000
          rIndex = parseInt(@randomSequence[seed1] * 500)
    
    return arr
  
  getRandom: (nTile) ->
    # Ensure nTile does not exceed length of random look up table
    nTile = nTile % 10000
    
    # Get random number from predefined sequence
    r = @constructor.randomSequence[nTile]
    
    # Compute offset using random
    offset = parseInt(500 * r)
    
    # Return random number based on tile number and offset
    return @constructor.randomSequence[offset]
    
  # Even though compressed images are represented as a binary table
  # the API should expose the same method as images.
  # TODO: Support compressed data cubes
  getFrame: (nFrame, callback, opts) ->
    
    # Check if heap in memory
    if @heap
      
      @frame = nFrame or @frame
      
      # TODO: Row parameters should be adjusted when working with data cubes
      @getRows(0, @rows, callback, opts)
      
    else
      # Get blob representing heap
      heapBlob = @blob.slice(@length, @length + @heapLength)
      
      # Create file reader
      reader = new FileReader()
      reader.onloadend = (e) =>
        @heap = e.target.result
        
        # Call function again
        @getFrame(nFrame, callback, opts)
      
      reader.readAsArrayBuffer(heapBlob)

@astro.FITS.CompressedImage = CompressedImage