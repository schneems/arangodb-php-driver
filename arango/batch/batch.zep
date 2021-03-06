
namespace Arango\Batch;

use Arango\Http\Api;
use Arango\Http\Url;
use Arango\Http\Client;
use Arango\Http\Response;
use Arango\Cursor\Cursor;
use Arango\Connection\Connection;
use Arango\Exception\ClientException;

/**
 * Provides batching functionality
 *
 * @package Arango/Batch
 * @class Batch
 * @author Lucas S. Vieira
 */
class Batch {

  /**
   * Document type
   *
   * @var string
   */
  private documentType = "Document" {
    get, set
  };

  /**
   * Batch response object
   *
   * @var Response
   */
  private batchResponse;

  /**
   * Flag that signals if this batch was processed or not
   *
   * @var boolean
   */
  private processed = false;

  /**
   * Batch size
   *
   * @var int
   */
  private batchSize;

  /**
   * An array of BatchPart objects
   *
   * @var array
   */
  private batchParts = [];

  /**
   * The next batch part Id
   *
   * @var int
   */
  private nextBatchPartId;

  /**
   * An array of batchPartCursor options
   *
   * @var array
   */
  private batchPartCursorOptions = [];

  /**
   * The connection object
   *
   * @var Connection
   */
  private connection;

  /**
   * The sanitize default value
   *
   * @var boolean
   */
  private sanitize = false;

  /**
   * The batch next id
   *
   * @var integer
   */
  private nextId;

  /**
   * Constructor for Batch instance. Batch instance by default starts capturing request after initiated.
   * To disable this, pass startCapture=>false inside the options array parameter
   *
   * @param Connection connection
   * @param array      options
   *
   * Options are:
   * "sanitize" = True to remove _id and _rev attributes from result documents returned from this batch. Defaults to false.
   * "startCapture" = Start batch capturing immediately after batch instantiation. Defaults to true.
   * "batchSize" = Defines a fixed array size for holding the batch parts. The id's of the batch parts can only be integers.
   *             When this option is defined, the batch mechanism will use an SplFixedArray instead of the normal PHP arrays.
   *             In most cases, this will result in increased performance of about 5% to 15%, depending on batch size and data.
   *
   */
  public function __construct(<Connection> connection, array options = []) {

    if(isset(options["sanitize"])) {
      let this->sanitize = (boolean) options["sanitize"];
    }

    if(isset(options["batchSize"]) && options["batchSize"] > 0) {
      let this->batchSize = (int) options["batchSize"];
      let this->batchParts = new \SplFixedArray(this->batchSize);
    }

    this->setConnection(connection);

    let this->batchPartCursorOptions = [Cursor::ENTRY_SANITIZE : this->sanitize];

    if (isset(options["startCapture"]) && (boolean) options["startCapture"]) {
      this->startCapture();
    }
  }

  /**
   * Sets the connection for current batch
   *
   * @param Connection connection
   * @return void
   */
  public function setConnection(<Connection> connection) -> void {
    let this->connection = connection;
  }

  /**
   * Get this batch connection
   *
   * @return \Arango\Connection\Connection
   */
  public function getConnection() -> <Connection> {
    return this->connection;
  }

  /**
   * Sets the batch's associated connection into capture mode.
   *
   * @param boolean state
   *
   * @return void
   */
  public function setCapture(boolean state) -> void {
    this->connection->setCaptureBatch(state);
  }

  /**
   * Sets connection into Batch-Request mode.
   * This is necessary to distinguish between normal and the batch request.
   *
   * @param boolean state
   *
   * @return void
   */
  public function setBatchRequest(boolean state) -> void {
    this->connection->setBatchRequest(state);
    let this->processed = true;
  }

  /**
   * Sets the batch active in its associated connection
   *
   * @return void
   */
  public function setActive() -> void {
    this->connection->setActiveBatch(this);
  }

  /**
   * Returns true, if this batch is active in its associated connection
   *
   * @return boolean
   */
  public function isActive() -> boolean {
    return this === this->connection->getActiveBatch();
  }

  /**
   * Returns true, if this batch is capturing requests
   *
   * @return boolean
   */
  public function isCapturing() -> boolean {
    return this->connection->isInBatchCaptureMode();
  }

  /**
   * Activates the batch.
   * This sets the batch active in its associated connection and also starts capturing.
   *
   * @return void
   */
  public function startCapture() -> void {
    this->setActive();
    this->setCapture(true);
  }

  /**
   * Stop capturing requests.
   * If the batch has not been processed yet,
   * more requests can be appended by calling startCapture() again.
   *
   * @throws \Arango\Exception\ClientException
   *
   * @return void
   */
  public function stopCapture() -> void {

    if(this->isActive() && this->isCapturing()) {
      this->setCapture(false);
      return;
    }

    throw new ClientException("Cannot stop capturing with this batch. Batch is not active");
  }

  /**
   * Sets the id of the next batch-part.
   * The id can later be used to retrieve the batch-part.
   *
   * @param mixed batchPartId
   *
   * @return void
   */
  public function nextBatchPartId(batchPartId) -> void {
    let this->nextBatchPartId = batchPartId;
  }

  /**
   * Set client side cursor options (for example: sanitize) for the next batch part.
   *
   * @param mixed batchPartCursorOptions
   *
   * @return void
   */
  public function nextBatchPartCursorOptions(batchPartCursorOptions) -> void {
    let this->batchPartCursorOptions = batchPartCursorOptions;
  }

  /**
   * Append the request to the batch-part
   *
   * @throws \Arango\Exception\ClientException
   *
   * @param string method   - The method of request
   * @param string request  - The request that will get appended to the batch
   *
   * @return \Arango\Http\Response
   */
  public function append(string method, string request) -> <Response> {
    var regs, type, batchPart, batchPartId, result, response;

    if(!Client::isValidMethod(method)){
      throw new ClientException("Invalid HTTP method supplied for batch");
    }

    preg_match("%/_api/simple/(?P<simple>\w*)|/_api/(?P<direct>\w*)%ix", request, regs);

    if(!isset(regs["direct"])){
      let regs["direct"] = "";
    }

    let type = regs["direct"] != "" ? regs["direct"] : regs["simple"];

    if(method == Client::GET && type == regs["direct"]){
      let type = "get" . type;
    }

    if(is_null(this->nextBatchPartId)) {
      var nextNumeric = 0;
      if(is_a(this->batchParts, "\\SplFixedArray")) {
        let nextNumeric = this->nextId;
        let this->nextId = this->nextId + 1;
      } else {
        let nextNumeric = count(this->batchParts);
      }

      let batchPartId = nextNumeric;
    } else {
      let batchPartId = this->nextBatchPartId;
      let this->nextBatchPartId = null;
    }

    let result = "HTTP/1.1 202 Accepted " . Client::EOL;
    let result = result . "location: /_db/_system/_api/document/0/0" . Client::EOL;
    let result = result . "content-type: application/json; charset=utf-8" . Client::EOL;
    let result = result . "etag: \"0\"" . Client::EOL;
    let result = result . "connection: Close" . Client::EOL;
    let result = result . "{\"error\":false,\"_id\":\"0/0\",\"id\":\"0\",\"_rev\":0,\"hasMore\":1, \"result\":[{}], \"documents\":[{}]}". Client::EOL;

    let response = new Response(result);

    let batchPart = new BatchPart(this, batchPartId, type, request, response, [
      "cursorOptions" : this->batchPartCursorOptions,
      "_documentClass" : this->documentType
    ]);

    let this->batchParts[batchPartId] = batchPart;
    response->setBatchPart(batchPart);

    return response;
  }

  /**
   * Split batch request and use ContentId as array key
   *
   * @throws \Arango\Exception\ClientException
   *
   * @param mixed pattern
   * @param mixed content
   *
   * @return array
   */
  public function splitWithContentIdKey(pattern, content) -> array {
    array data;
    var exploded;

    let exploded = explode(pattern, content);

    var key, value;
    for key, value in exploded {
      var response, contentId;
      let response = new Response(value);
      let contentId = response->getHeader("Content-Id");

      if(!is_null(contentId)) {
        let data[contentId] = value;
        continue;
      }

      let data[key] = value;
    }

    return data;
  }

  /**
   * Processes this batch. This sends the captured requests to the server as one batch.
   * Batch if processing of the batch was successful or the HttpResponse object in case of a failure.
   * A successful process just means that tha parts were processed.
   * Each part has it's own response though and should be checked on its own.
   *
   * @throws \Arango\Exception\ClientException
   * @throws \Arango\Exception\Exception
   *
   * @return \Arango\Http\Response | \Arango\Batch\Batch
   */
  public function process() -> <Response> | <Batch> {
    var data, batchParts, combinedDataHeader;

    if(this->isCapturing()) {
      this->stopCapture();
    }

    this->setBatchRequest(true);
    let data = "";
    let batchParts = this->batchParts;

    if(count(batchParts) == 0) {
      throw new ClientException("Cannot process empty batch");
    }

    let combinedDataHeader = "--" . Client::MIME_BOUNDARY . Client::EOL;
    let combinedDataHeader = combinedDataHeader . "Content-Type: application/x-arango-batchpart" . Client::EOL;

    var batchValue;
    for _, batchValue in batchParts {
      if(is_null(batchValue)) {
        continue;
      }

      let data = data . combinedDataHeader;

      if(!is_null(batchValue->getId())) {
        let data = data . "Content-Id: " . (string) batchValue->getId() . Client::SEPARATOR;
      } else {
        let data = data . Client::EOL;
      }

      let data = data . (string) batchValue->getRequest() . Client::EOL;
    }

    let data = data . "--" . Client::MIME_BOUNDARY . "--" . Client::SEPARATOR;

    var params, url;
    let params = [];
    let url = Url::appendParamsToUrl(Api::BATCH, params);
    let this->batchResponse = this->connection->post(url, data);

    if(this->batchResponse->getCode() != 200) {
      return this->batchResponse;
    }

    var body;

    let body = this->batchResponse->getBody();
    let body = trim(body, "--" . Client::MIME_BOUNDARY . "--");
    let batchParts = this->splitWithContentIdKey("--" . Client::MIME_BOUNDARY . Client::EOL, body);

    var key, value;
    for key, value in batchParts {
      var response, batchPartsResponses;

      let response = new Response(value);
      let body = response->getBody();
      let batchPartsResponses[key] = response;
      this->getPart(key)->setResponse(batchPartsResponses[key]);
    }

    return this;
  }

  /**
   * Get the batch part identified by array key
   * or its ID (if it was set with nextBatchPartId($id))
   *
   * @throws \Arango\Exception\ClientException
   *
   * @param mixed partId The batch part ID
   *
   * @return batchPart
   */
  public function getPart(partId) -> <BatchPart> {
    if(isset(this->batchParts[partId])) {
      return this->batchParts[partId];
    }

    throw new ClientException("Request batch part does not exist.");
  }
}
